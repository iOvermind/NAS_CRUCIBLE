#!/bin/bash
# =========================================================================
# M3: ISO 端到端開機驗證 (QEMU)
#
# 這一層驗的是 stub 永遠測不到的東西：真的能不能開機、開機碟會不會被自己抹掉、
# 持久分區在重開機後還在不在、以及五類 Device Class 在真實核心與 smartctl 下
# 的分類結果。跑一輪要數分鐘到十幾分鐘，因此不進 run_all.sh，release 前手動跑。
#
# 用法: tests/run_iso.sh [ISO 檔]     (省略時取 build/out 內最新的 ISO)
#
# 注意：QEMU 模擬碟的 SMART 支援很薄，smartctl -t long 與 NVMe device-self-test
# 在 VM 內基本上跑不起來。那部分的覆蓋在 tests/run_all.sh，這裡不重複。
# =========================================================================
set -u
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
WORK=$(mktemp -d); QPID=""; SERIAL_FD_OPEN=false
KEEP_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)/build/out/iso-test-logs"
cleanup() {
    [ -n "$QPID" ] && kill "$QPID" 2>/dev/null
    # 失敗時保留序列埠 log：VM 一結束就什麼都不剩，沒有 log 根本無從診斷。
    if [ "${fail:-0}" -gt 0 ] 2>/dev/null; then
        mkdir -p "$KEEP_DIR" && cp "$WORK"/*.log "$KEEP_DIR"/ 2>/dev/null \
            && echo "序列埠 log 已保留於 $KEEP_DIR"
    fi
    rm -rf "$WORK"
}
trap cleanup EXIT

pass=0; fail=0
check() { if [ "$2" = 0 ]; then printf "  ✅ %s\n" "$1"; pass=$((pass+1))
          else printf "  ❌ %s\n" "$1"; fail=$((fail+1)); fi; }
die() { echo "❌ $*" >&2; exit 2; }

# ------------------------------------------------------------- 前置檢查 --
ISO=${1:-}
if [ -z "$ISO" ]; then
    ISO=$(ls -t "$ROOT"/build/out/*.iso 2>/dev/null | head -1)
fi
[ -n "$ISO" ] && [ -f "$ISO" ] || die "找不到 ISO。先跑 ./build/build_iso.sh，或直接指定路徑。"

command -v qemu-system-x86_64 >/dev/null 2>&1 \
    || die "缺少 qemu-system-x86_64。請安裝: sudo apt install qemu-system-x86 ovmf"
command -v qemu-img >/dev/null 2>&1 || die "缺少 qemu-img (qemu-utils)"

OVMF_DIR=/usr/share/OVMF
OVMF_CODE="$OVMF_DIR/OVMF_CODE_4M.fd"
OVMF_VARS="$OVMF_DIR/OVMF_VARS_4M.fd"
OVMF_CODE_SB="$OVMF_DIR/OVMF_CODE_4M.secboot.fd"
OVMF_VARS_MS="$OVMF_DIR/OVMF_VARS_4M.ms.fd"
[ -f "$OVMF_CODE" ] || die "缺少 OVMF 韌體 ($OVMF_CODE)。請安裝: sudo apt install ovmf"

ACCEL=tcg
[ -r /dev/kvm ] && [ -w /dev/kvm ] && ACCEL=kvm
BOOT_TIMEOUT=${CRUCIBLE_BOOT_TIMEOUT:-300}
[ "$ACCEL" = tcg ] && BOOT_TIMEOUT=$((BOOT_TIMEOUT * 3))

echo "ISO      : $ISO"
echo "加速     : $ACCEL (timeout ${BOOT_TIMEOUT}s)"
echo ""

# --------------------------------------------------------- 虛擬硬體佈署 --
# 開機碟：把 ISO dd 進一個比它大的 raw image，模擬「寫入隨身碟」。
# 大出來的尾端空間正是 Evidence Store 要用的地方。
USB="$WORK/usb.img"
iso_mb=$(( ($(stat -c%s "$ISO") + 1048575) / 1048576 ))
qemu-img create -q -f raw "$USB" "$(( iso_mb + 2048 ))M"
dd if="$ISO" of="$USB" conv=notrunc status=none

for d in sata_hdd sata_ssd sas_hdd nvme dirty; do
    qemu-img create -q -f raw "$WORK/$d.img" 64M
done
# 「碟上有既有資料」的碟：寫一個 ext4 superblock 進去。
if command -v mkfs.ext4 >/dev/null 2>&1; then
    mkfs.ext4 -q -F "$WORK/dirty.img" 2>/dev/null
    HAVE_DIRTY=true
else
    echo "⚠️  宿主缺少 mkfs.ext4，略過 Signature 偵測的端到端驗證"
    HAVE_DIRTY=false
fi

QEMU_DISKS=()
build_disk_args() {
    QEMU_DISKS=(
        -device qemu-xhci,id=xhci \
        -drive "if=none,id=usb,file=$USB,format=raw" \
        -device "usb-storage,bus=xhci.0,drive=usb,bootindex=0,serial=SN-BOOTUSB" \
        -device ich9-ahci,id=ahci \
        -drive "if=none,id=d1,file=$WORK/sata_hdd.img,format=raw" \
        -device "ide-hd,bus=ahci.0,drive=d1,rotation_rate=7200,serial=SN-SATAHDD" \
        -drive "if=none,id=d2,file=$WORK/sata_ssd.img,format=raw" \
        -device "ide-hd,bus=ahci.1,drive=d2,rotation_rate=1,serial=SN-SATASSD" \
        -device megasas,id=sas \
        -drive "if=none,id=d3,file=$WORK/sas_hdd.img,format=raw" \
        -device "scsi-hd,bus=sas.0,drive=d3,rotation_rate=15000,serial=SN-SASHDD" \
        -drive "if=none,id=d4,file=$WORK/nvme.img,format=raw" \
        -device "nvme,drive=d4,serial=SN-NVME" \
        -drive "if=none,id=d5,file=$WORK/dirty.img,format=raw" \
        -device "ide-hd,bus=ahci.2,drive=d5,rotation_rate=7200,serial=SN-DIRTY"
    )
}
build_disk_args

PORT=$(( 14000 + RANDOM % 2000 ))
LOG=""
MACHINE="q35,accel=$ACCEL"

boot_vm() { # boot_vm <log 檔> <firmware 參數...>
    LOG=$1; shift
    : > "$LOG"
    local fw=("$@")
    # 每次開機換一個 port：上一輪的 listener 可能還在 TIME_WAIT。
    PORT=$(( PORT + 1 ))
    SERIAL_FD_OPEN=false
    # wait=on：QEMU 等我們接上序列埠才開始，開機初期的輸出不會漏掉。
    qemu-system-x86_64 \
        -machine "$MACHINE" -m 2048 -smp 2 \
        "${fw[@]}" \
        "${QEMU_DISKS[@]}" \
        -display none -no-reboot \
        -serial "tcp:127.0.0.1:$PORT,server=on,wait=on" \
        >"$LOG.qemu" 2>&1 &
    QPID=$!
    # 注意 2>/dev/null 要掛在迴圈上，不能掛在 exec 上：exec 一旦成功，
    # 那個重導向會套用到整個 shell，之後所有 stderr 都會被吞掉。
    local i
    for i in $(seq 1 100); do
        if exec 3<>"/dev/tcp/127.0.0.1/$PORT"; then SERIAL_FD_OPEN=true; break; fi
        sleep 0.2
    done 2>/dev/null
    [ "$SERIAL_FD_OPEN" = true ] || { echo "  (無法連上 QEMU 序列埠)"; return 1; }
    cat <&3 >>"$LOG" &
}

stop_vm() {
    [ "$SERIAL_FD_OPEN" = true ] && exec 3<&- 2>/dev/null && exec 3>&- 2>/dev/null
    SERIAL_FD_OPEN=false
    [ -n "$QPID" ] && kill "$QPID" 2>/dev/null
    wait "$QPID" 2>/dev/null
    QPID=""
}

wait_for() { # wait_for <字串> <秒數>
    local pat=$1 secs=$2 i
    for (( i=0; i<secs*2; i++ )); do
        grep -qF "$pat" "$LOG" 2>/dev/null && return 0
        kill -0 "$QPID" 2>/dev/null || { sleep 1; grep -qF "$pat" "$LOG" && return 0; return 1; }
        sleep 0.5
    done
    return 1
}
send() { printf '%s\n' "$1" >&3; }

# 開機成功的標記取自 crucible-evidence-store.service。
# 不能用 crucible-autostart 的橫幅 —— 那支跑在 tty1，輸出不會進序列埠；
# 這個 unit 設了 StandardOutput=journal+console，而 console 就是 ttyS0。
BOOTMARK="[evidence-store]"

# 確認真的進到可用的 userspace，而不只是 systemd 跑了幾個 unit。
#
# 送出去的指令會被 VM 的 tty 行規回顯，因此「等待某字串出現」很容易被自己送的
# 那一行命中。所有標記都用 "" 切開，讓回顯的輸入 (CRUCIBLE""_SHELL_OK) 與真正
# 執行後的輸出 (CRUCIBLE_SHELL_OK) 長得不一樣。
shell_alive() {
    send "echo CRUCIBLE\"\"_SHELL_OK_$1"
    wait_for "CRUCIBLE_SHELL_OK_$1" 120
}

# BOOTMARK 出現時 serial-getty 通常還沒登入完，這時送出去的指令會被 login
# 程序吃掉而不是交給 shell。
#
# 不能改成「等提示字元出現再說話」：實測 bash 在序列埠上要收到輸入才會把提示
# 字元吐出來，空等只會逾時。改為反覆送、每次短等，早期幾次被 login 吃掉，
# 之後就會落進 shell。
wait_shell() {
    local i
    for i in 1 2 3 4 5 6; do
        send ""
        send "echo CRUCIBLE\"\"_SHELL_OK_$1"
        wait_for "CRUCIBLE_SHELL_OK_$1" 20 && return 0
    done
    return 1
}

# ============================================ 1. Legacy BIOS 開機路徑 ==
echo "== Legacy BIOS (SeaBIOS) =="
boot_vm "$WORK/bios.log"
wait_for "$BOOTMARK" "$BOOT_TIMEOUT"
check "isohybrid MBR 可由 BIOS 開機並進到 userspace" "$?"
wait_shell bios
check "序列埠取得可用的 root shell" "$?"
# 不能用 pgrep 找 crucible-autostart：它最後會 exec 成 fbterm/tmux，
# 行程映像被取代，名字就消失了。改為確認 tmux session 真的起來。
send "tmux ls 2>&1 | head -2"
wait_for "burnin" 60
check "tty1 的 tmux session (burnin) 已建立" "$?"
grep -qF "Evidence Store 就緒" "$WORK/bios.log"
check "首次開機在隨身碟尾端建立 Evidence Store" "$?"
grep -qF "降級為 No-Persistence Mode" "$WORK/bios.log"
check "未進入 No-Persistence Mode" "$([ $? -ne 0 ]; echo $?)"
stop_vm

# ================================== 2. 重開機後 Evidence Store 仍在 ==
echo
echo "== 重新開機 (持久化) =="
boot_vm "$WORK/reboot.log"
wait_for "掛載既有的 Evidence Store 成功" "$BOOT_TIMEOUT"
check "重開機後掛回同一個 Evidence Store (未重建)" "$?"
stop_vm

# ============================================== 3. UEFI 開機路徑 ==
echo
echo "== UEFI (OVMF) =="
cp "$OVMF_VARS" "$WORK/vars.fd"
boot_vm "$WORK/uefi.log" \
    -drive "if=pflash,format=raw,unit=0,readonly=on,file=$OVMF_CODE" \
    -drive "if=pflash,format=raw,unit=1,file=$WORK/vars.fd"
wait_for "$BOOTMARK" "$BOOT_TIMEOUT"
check "isohybrid GPT 可由 UEFI 開機並進到 userspace" "$?"
wait_shell uefi
check "UEFI 開機後序列埠取得可用的 root shell" "$?"
stop_vm

# ====================================== 4. Secure Boot 開機路徑 ==
echo
echo "== UEFI + Secure Boot (微軟金鑰已註冊) =="
if [ -f "$OVMF_CODE_SB" ] && [ -f "$OVMF_VARS_MS" ]; then
    cp "$OVMF_VARS_MS" "$WORK/vars_ms.fd"
    MACHINE="q35,accel=$ACCEL,smm=on"
    boot_vm "$WORK/sb.log" \
        -global driver=cfi.pflash01,property=secure,value=on \
        -drive "if=pflash,format=raw,unit=0,readonly=on,file=$OVMF_CODE_SB" \
        -drive "if=pflash,format=raw,unit=1,file=$WORK/vars_ms.fd"
    wait_for "$BOOTMARK" "$BOOT_TIMEOUT"
    check "shim + 簽章 grub + 官方 kernel 通過 Secure Boot" "$?"
    stop_vm
    MACHINE="q35,accel=$ACCEL"
else
    echo "  ⏭  略過 (缺少 $OVMF_CODE_SB 或 $OVMF_VARS_MS)"
fi

# ================================ 5. Admission：分類矩陣與安全規則 ==
echo
echo "== Admission (5 類分類 / 開機碟排除 / Signature) =="
boot_vm "$WORK/adm.log"
if wait_for "$BOOTMARK" "$BOOT_TIMEOUT" && wait_shell adm; then
    # serial-getty 已設為自動登入，這裡直接就是 root shell。
    # crucible.sh 的 tmux 防呆以 TMUX=1 滿足 —— 序列埠上沒有 SSH 斷線風險。
    send "export TMUX=1 CRUCIBLE_LOG_DIR=/tmp/adm"
    send "printf 'no\\n' | /opt/nas_crucible/crucible.sh \$(lsblk -dno NAME,TYPE | awk '\$2==\"disk\"{print \$1}' | tr '\\n' ' ') >/tmp/adm.out 2>&1; echo ADM\"\"_RC=\$?"
    wait_for "ADM_RC=" "$BOOT_TIMEOUT"
    send "echo MFB\"\"EGIN; cat /tmp/adm/device_manifest.json | tr -d '\\n'; echo; echo MFE\"\"ND"
    wait_for "MFEND" 120

    MF="$WORK/manifest.json"
    # 不能用行首錨點：標記前面會有 bash 的 ANSI 逸出序列 (bracketed paste)。
    # 送進去的指令用 "" 切開過，所以不加錨點也不會匹配到自己的回顯。
    sed -n '/MFBEGIN/,/MFEND/p' "$WORK/adm.log" \
        | sed '1d;$d' | tr -d '\r' | grep -m1 '^{' > "$MF"
    if jq -e . "$MF" >/dev/null 2>&1; then
        q() { jq -r "$1" "$MF" 2>/dev/null; }
        cls_of() { jq -r --arg s "$1" '.devices[] | select(.serial==$s) | .class' "$MF"; }
        dec_of() { jq -r --arg s "$1" '.devices[] | select(.serial==$s) | .decision' "$MF"; }
        rsn_of() { jq -r --arg s "$1" '.devices[] | select(.serial==$s) | .block_reason' "$MF"; }

        check "manifest 取回成功 ($(q '.devices|length') 顆裝置)" 0
        check "開機碟被擋: BOOT_MEDIUM" \
              "$([ "$(rsn_of SN-BOOTUSB)" = BOOT_MEDIUM ]; echo $?)"
        check "SATA HDD 分類為 SATA_HDD (rotation_rate=7200)" \
              "$([ "$(cls_of SN-SATAHDD)" = SATA_HDD ]; echo $?)"
        check "SATA SSD 分類為 SATA_SSD (rotation_rate=1)" \
              "$([ "$(cls_of SN-SATASSD)" = SATA_SSD ]; echo $?)"
        check "SAS HDD 分類為 SAS_HDD (megaraid_sas 直通)" \
              "$([ "$(cls_of SN-SASHDD)" = SAS_HDD ]; echo $?)"
        check "NVMe 分類為 NVME_SSD" \
              "$([ "$(cls_of SN-NVME)" = NVME_SSD ]; echo $?)"
        check "乾淨的碟通過 admission" \
              "$([ "$(dec_of SN-SATAHDD)" = ALLOW ]; echo $?)"
        if [ "$HAVE_DIRTY" = true ]; then
            check "有 ext4 簽章的碟被擋: HAS_DATA" \
                  "$([ "$(rsn_of SN-DIRTY)" = HAS_DATA ]; echo $?)"
        fi
    else
        check "manifest 取回成功" 1
        # 把 VM 內的實際情形倒進序列埠，log 才有東西可看。
        send "echo ---ADMOUT---; tail -20 /tmp/adm.out; echo ---LSDIR---; ls -la /tmp/adm/ 2>&1 | head -20"
        wait_for "---LSDIR---" 60
        command sleep 3 2>/dev/null || true
    fi
else
    check "Admission 測試：VM 未開機成功" 1
fi
stop_vm

echo
echo "-------------------------------"
printf "通過 %d / 失敗 %d\n" "$pass" "$fail"
[ "$fail" -eq 0 ]
