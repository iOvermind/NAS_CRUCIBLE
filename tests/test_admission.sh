#!/bin/bash
# =========================================================================
# Admission 防線測試 (Signature / Boot Medium / Override / 部分放行)
#
# 為什麼這支測試存在：
#   Live Image 開機時主系統不會啟動，於是「已掛載 / 在 ZFS pool 內 /
#   被 LVM 佔用」這三道既有防線同時歸零 —— 一顆服役中的資料碟看起來會跟
#   全新空碟一模一樣。Signature 偵測是補回來的那道防線，Boot Medium 排除
#   則是防止工具抹掉自己。這兩者一旦失效不會有任何錯誤訊息，只會安靜地
#   把資料抹掉，所以必須被測試鎖住。見 docs/adr/0001 與 0003。
# =========================================================================
set -u
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT

pass=0; fail=0
check() { # check <說明> <rc>
    if [ "$2" = 0 ]; then printf "  ✅ %s\n" "$1"; pass=$((pass+1))
    else printf "  ❌ %s\n" "$1"; fail=$((fail+1)); fi
}

# ---------------------------------------------------------------- stubs --
export STUB_DIR="$TMP/stub"
mkdir -p "$STUB_DIR" "$TMP/bin" "$TMP/dev" "$TMP/sys/block"

cat > "$TMP/bin/lsblk" <<'EOF'
#!/bin/bash
# stub lsblk：輸出取自 $STUB_DIR/<dev>.<欄位>
args="$*"; dev=""
for a in "$@"; do case "$a" in /dev/*) dev=$(basename "$a") ;; esac; done
case "$args" in
    *NAME,FSTYPE,PTTYPE*)
        if [ -f "$STUB_DIR/$dev.sig" ]; then cat "$STUB_DIR/$dev.sig"
        elif [ -n "$dev" ]; then echo "$dev  "; fi ;;
    *MOUNTPOINT*) cat "$STUB_DIR/$dev.mount" 2>/dev/null ;;
    *TRAN*)       cat "$STUB_DIR/$dev.tran"  2>/dev/null ;;
    *PKNAME*)     cat "$STUB_DIR/$dev.pkname" 2>/dev/null ;;
esac
exit 0
EOF

cat > "$TMP/bin/findmnt" <<'EOF'
#!/bin/bash
case "$*" in
    "-no SOURCE -M /run/live/medium") cat "$STUB_DIR/medium.src" 2>/dev/null ;;
    "-nro SOURCE,FSTYPE")             cat "$STUB_DIR/mounts"     2>/dev/null ;;
    "-no FSTYPE -M /")                cat "$STUB_DIR/rootfstype" 2>/dev/null ;;
esac
exit 0
EOF

cat > "$TMP/bin/smartctl" <<'EOF'
#!/bin/bash
dev=""
for a in "$@"; do case "$a" in /dev/*) dev=$(basename "$a") ;; esac; done
if [ -f "$STUB_DIR/$dev.smart" ]; then cat "$STUB_DIR/$dev.smart"; exit 0; fi
exit 1
EOF
chmod +x "$TMP/bin/"*
export PATH="$TMP/bin:$PATH"

source "$ROOT/lib/device_probe.sh"

mk_smart() { # mk_smart <dev> <serial> <protocol> <rotation|ABSENT>
    if [ "$4" = ABSENT ]; then
        jq -n --arg s "$2" --arg p "$3" \
          '{serial_number:$s, model_name:"TESTMODEL", device:{protocol:$p}}' > "$STUB_DIR/$1.smart"
    else
        jq -n --arg s "$2" --arg p "$3" --argjson r "$4" \
          '{serial_number:$s, model_name:"TESTMODEL", device:{protocol:$p}, rotation_rate:$r}' > "$STUB_DIR/$1.smart"
    fi
}

# ================================================= 1. dev_has_signature ==
echo "== dev_has_signature =="
sig() { # sig <說明> <lsblk 輸出> <期望 rc>
    printf '%s\n' "$2" > "$STUB_DIR/sdt.sig"
    dev_has_signature sdt; local got=$?
    check "$1 (rc=$got, 期望 $3)" "$([ "$got" = "$3" ]; echo $?)"
}
sig "全新空碟：無 FSTYPE 無 PTTYPE"            "sdt  "                 1
sig "整碟 ext4"                                 "sdt ext4 "             0
sig "只有分割表、尚未建檔案系統"                "sdt  gpt"              0
sig "ZFS 成員在分割區上 (整碟 pool 的常見形狀)" "$(printf 'sdt  gpt\nsdt1 zfs_member gpt')" 0
sig "LVM PV"                                    "sdt LVM2_member "      0
sig "mdraid 成員"                               "sdt linux_raid_member " 0
sig "LUKS"                                      "sdt crypto_LUKS "      0
rm -f "$STUB_DIR/sdt.sig"
# lsblk 連裝置自己那一行都印不出來 => 不是「乾淨」，是「沒看懂」，必須 Fail-Closed
cat > "$TMP/bin/lsblk" <<'EOF'
#!/bin/bash
exit 0
EOF
chmod +x "$TMP/bin/lsblk"
dev_has_signature sdt; got=$?
check "lsblk 無輸出時回傳 2 (無法判定，不可當成乾淨) (rc=$got)" "$([ "$got" = 2 ]; echo $?)"
# 還原 stub
cat > "$TMP/bin/lsblk" <<'EOF'
#!/bin/bash
args="$*"; dev=""
for a in "$@"; do case "$a" in /dev/*) dev=$(basename "$a") ;; esac; done
case "$args" in
    *NAME,FSTYPE,PTTYPE*)
        if [ -f "$STUB_DIR/$dev.sig" ]; then cat "$STUB_DIR/$dev.sig"
        elif [ -n "$dev" ]; then echo "$dev  "; fi ;;
    *MOUNTPOINT*) cat "$STUB_DIR/$dev.mount" 2>/dev/null ;;
    *TRAN*)       cat "$STUB_DIR/$dev.tran"  2>/dev/null ;;
    *PKNAME*)     cat "$STUB_DIR/$dev.pkname" 2>/dev/null ;;
esac
exit 0
EOF
chmod +x "$TMP/bin/lsblk"

# ================================================== 2. dev_is_removable ==
echo
echo "== dev_is_removable =="
export SYSFS_ROOT="$TMP/sys"
mkdir -p "$TMP/sys/block/sdr" "$TMP/sys/block/sdf" "$TMP/sys/block/sdu"
echo 1 > "$TMP/sys/block/sdr/removable"
echo 0 > "$TMP/sys/block/sdf/removable"
echo 0 > "$TMP/sys/block/sdu/removable"
echo usb > "$STUB_DIR/sdu.tran"
dev_is_removable sdr; check "sysfs removable=1 判為可移除" "$?"
dev_is_removable sdu; check "TRAN=usb 判為可移除 (removable=0 的 USB 外接盒)" "$?"
dev_is_removable sdf; check "內接 SATA 不判為可移除" "$([ $? -ne 0 ]; echo $?)"

# ================================================= 3. detect_boot_medium ==
echo
echo "== detect_boot_medium =="
echo "/dev/sdb1" > "$STUB_DIR/medium.src"
echo "sdb"       > "$STUB_DIR/sdb1.pkname"
got=$(detect_boot_medium); rc=$?
check "由 /run/live/medium 反查到整顆碟 sdb (得到 '$got')" "$([ "$rc" = 0 ] && [ "$got" = sdb ]; echo $?)"

rm -f "$STUB_DIR/medium.src"
printf '/dev/sdc1 iso9660\n' > "$STUB_DIR/mounts"
echo "sdc" > "$STUB_DIR/sdc1.pkname"
got=$(detect_boot_medium); rc=$?
check "退路：掛載中的 iso9660 反查到 sdc (得到 '$got')" "$([ "$rc" = 0 ] && [ "$got" = sdc ]; echo $?)"

rm -f "$STUB_DIR/mounts"
detect_boot_medium >/dev/null; rc=$?
check "什麼都反查不到時回傳 1 (呼叫端必須退化，不可當成沒有開機碟)" "$([ "$rc" = 1 ]; echo $?)"

# loop 裝置往回追到承載映像的實體分割區
mkdir -p "$TMP/sys/block/loop0/loop"
echo "$TMP/boot.iso" > "$TMP/sys/block/loop0/loop/backing_file"
printf '/dev/loop0 iso9660\n' > "$STUB_DIR/mounts"
cat > "$TMP/bin/findmnt" <<'EOF'
#!/bin/bash
case "$*" in
    "-nro SOURCE,FSTYPE") cat "$STUB_DIR/mounts" 2>/dev/null ;;
    "-no SOURCE -T "*)    echo "/dev/sdd1" ;;
esac
exit 0
EOF
chmod +x "$TMP/bin/findmnt"
echo "sdd" > "$STUB_DIR/sdd1.pkname"
got=$(detect_boot_medium); rc=$?
check "loop 裝置追回實體碟 sdd (toram / findiso 情境) (得到 '$got')" "$([ "$rc" = 0 ] && [ "$got" = sdd ]; echo $?)"
rm -f "$STUB_DIR/mounts"

# ================================================ 4. is_live_environment ==
echo
echo "== is_live_environment =="
export CRUCIBLE_LIVE_DIR="$TMP/nonexistent-live"
export CRUCIBLE_CMDLINE_FILE="$TMP/cmdline"
echo "BOOT_IMAGE=/vmlinuz root=/dev/sda1 ro quiet" > "$CRUCIBLE_CMDLINE_FILE"
cat > "$TMP/bin/findmnt" <<'EOF'
#!/bin/bash
case "$*" in "-no FSTYPE -M /") cat "$STUB_DIR/rootfstype" 2>/dev/null ;; esac
exit 0
EOF
chmod +x "$TMP/bin/findmnt"
echo ext4 > "$STUB_DIR/rootfstype"
is_live_environment; check "已安裝環境不判為 Live" "$([ $? -ne 0 ]; echo $?)"
echo "BOOT_IMAGE=/live/vmlinuz boot=live components quiet" > "$CRUCIBLE_CMDLINE_FILE"
is_live_environment; check "cmdline 帶 boot=live 判為 Live" "$?"
echo "BOOT_IMAGE=/vmlinuz root=/dev/sda1 ro quiet" > "$CRUCIBLE_CMDLINE_FILE"
echo overlay > "$STUB_DIR/rootfstype"
is_live_environment; check "根目錄是 overlay 判為 Live" "$?"
echo ext4 > "$STUB_DIR/rootfstype"
mkdir -p "$TMP/live-dir"; CRUCIBLE_LIVE_DIR="$TMP/live-dir" is_live_environment
check "/run/live 存在判為 Live" "$?"

# ============================================ 5. crucible.sh 端到端 admission ==
echo
echo "== crucible.sh admission (部分放行 / Override / Boot Medium) =="

# 測試以非 root、非 tmux 執行，並把「裝置節點是否存在」導向 $TMP/dev；
# 其餘邏輯完全沿用正式檔案。
sed -e 's/^if \[ "\$EUID" -ne 0 \]; then$/if false; then/' \
    -e 's/^if \[ -z "\${TMUX:-}" \].*$/if false; then/' \
    -e 's|\[ ! -b "/dev/\$dev" \]|[ ! -e "$CRUCIBLE_DEV_ROOT/$dev" ]|' \
    -e 's|\[ -b "/dev/\$dev" \]|[ -e "$CRUCIBLE_DEV_ROOT/$dev" ]|' \
    "$ROOT/crucible.sh" > "$TMP/crucible.sh"
chmod +x "$TMP/crucible.sh"
ln -sfn "$ROOT/lib" "$TMP/lib"
export CRUCIBLE_DEV_ROOT="$TMP/dev"
export CRUCIBLE_POLICY_DIR="$ROOT/policies"

grep -q 'CRUCIBLE_DEV_ROOT' "$TMP/crucible.sh" || {
    echo "  ❌ 測試接縫沒有套用成功 (crucible.sh 的裝置節點判斷已改寫？)"; fail=$((fail+1)); }

run_admission() { # run_admission <輸入> <dev...> -> 印出 log dir
    local input=$1; shift
    local ld="$TMP/logs/$RANDOM$RANDOM"; mkdir -p "$ld"
    printf '%s' "$input" | CRUCIBLE_LOG_DIR="$ld" "$TMP/crucible.sh" "$@" > "$ld/stdout" 2>&1
    echo "$?" > "$ld/rc"
    echo "$ld"
}
run_admission_tty() { # 與上者相同，但透過 pty 執行，讓 [ -t 0 ] 為真
    local input=$1; shift
    local ld="$TMP/logs/$RANDOM$RANDOM"; mkdir -p "$ld"
    local devs="$*"
    printf '%s' "$input" | script -qec \
        "CRUCIBLE_LOG_DIR='$ld' '$TMP/crucible.sh' $devs" /dev/null > "$ld/stdout" 2>&1
    echo "$?" > "$ld/rc"
    tr -d '\r' < "$ld/stdout" > "$ld/stdout.clean" && mv "$ld/stdout.clean" "$ld/stdout"
    echo "$ld"
}
dec() { jq -r --arg d "$2" '.devices[] | select(.device==$d) | .decision' "$1/device_manifest.json"; }
rsn() { jq -r --arg d "$2" '.devices[] | select(.device==$d) | .block_reason' "$1/device_manifest.json"; }
ovd() { jq -r --arg d "$2" '.devices[] | select(.device==$d) | .overridden' "$1/device_manifest.json"; }

: > "$TMP/dev/sdb"; : > "$TMP/dev/sdc"; : > "$TMP/dev/sdd"
mk_smart sdb SN-CLEAN ATA 7200      # 乾淨 SATA HDD
mk_smart sdc SN-DATA  ATA 7200      # 有 ext4 簽章
mk_smart sdd SN-MOUNT ATA 7200      # 已掛載
printf 'sdc ext4 \n' > "$STUB_DIR/sdc.sig"
echo "/mnt/data" > "$STUB_DIR/sdd.mount"

# --- Case 1: 部分放行 —— 一顆乾淨、一顆已掛載，不得整批中止 ---
ld=$(run_admission $'no\n' sdb sdd)
check "部分放行：乾淨碟 ALLOW" "$([ "$(dec "$ld" sdb)" = ALLOW ]; echo $?)"
check "部分放行：已掛載碟 BLOCK/MOUNTED (而非整批 exit 2)" \
      "$([ "$(dec "$ld" sdd)" = BLOCK ] && [ "$(rsn "$ld" sdd)" = MOUNTED ]; echo $?)"
check "部分放行：manifest 兩筆都在" \
      "$([ "$(jq '.devices|length' "$ld/device_manifest.json")" = 2 ]; echo $?)"
check "部分放行：仍走到 YES 確認 (輸入 no -> rc=130)" "$([ "$(cat "$ld/rc")" = 130 ]; echo $?)"

# --- Case 2: Signature 擋碟，且非互動情境不提供 Override ---
ld=$(run_admission $'no\n' sdc)
check "有 ext4 簽章的碟被 BLOCK/HAS_DATA" \
      "$([ "$(dec "$ld" sdc)" = BLOCK ] && [ "$(rsn "$ld" sdc)" = HAS_DATA ]; echo $?)"
check "全部被擋時不進 YES 確認，回傳 rc=1" "$([ "$(cat "$ld/rc")" = 1 ]; echo $?)"
check "非互動情境不提供 Override" \
      "$(grep -q '非互動執行一律維持封鎖' "$ld/stdout"; echo $?)"
check "被擋的碟仍寫進 manifest (判定紀錄必須留存)" \
      "$([ -f "$ld/device_manifest.json" ]; echo $?)"

# --- Case 3/4: 互動情境的 Override ---
if command -v script >/dev/null 2>&1; then
    ld=$(run_admission_tty $'SN-DATA\nno\n' sdc)
    check "輸入正確序號可解除封鎖 -> ALLOW" "$([ "$(dec "$ld" sdc)" = ALLOW ]; echo $?)"
    check "解除後標記 overridden=true (事後分辨得出是強制解除)" \
          "$([ "$(ovd "$ld" sdc)" = true ]; echo $?)"

    ld=$(run_admission_tty $'WRONG-SN\nno\n' sdc)
    check "輸入錯誤序號維持封鎖" \
          "$([ "$(dec "$ld" sdc)" = BLOCK ] && [ "$(rsn "$ld" sdc)" = HAS_DATA ]; echo $?)"

    ld=$(run_admission_tty $'\nno\n' sdc)
    check "直接 Enter 維持封鎖" "$([ "$(dec "$ld" sdc)" = BLOCK ]; echo $?)"

    # Override 只解除 Signature 這一條，不得順手解除其他任何原因
    ld=$(run_admission_tty $'SN-MOUNT\nno\n' sdd)
    check "已掛載的碟不提供 Override (輸入序號也無效)" \
          "$([ "$(dec "$ld" sdd)" = BLOCK ] && [ "$(rsn "$ld" sdd)" = MOUNTED ]; echo $?)"
else
    echo "  ⏭  略過 Override 互動測試 (系統缺少 script 指令)"
fi

# --- Case 5: 序號重複 -> 兩顆都擋 ---
: > "$TMP/dev/sde"
mk_smart sde SN-CLEAN ATA 7200      # 與 sdb 同序號
ld=$(run_admission $'no\n' sdb sde)
check "序號重複：兩顆都 BLOCK/DUPLICATE_SERIAL" \
      "$([ "$(rsn "$ld" sdb)" = DUPLICATE_SERIAL ] && [ "$(rsn "$ld" sde)" = DUPLICATE_SERIAL ]; echo $?)"
rm -f "$TMP/dev/sde" "$STUB_DIR/sde.smart"

# --- Case 6: Live 模式排除 Boot Medium ---
mkdir -p "$TMP/live-dir"
echo "/dev/sdb1" > "$STUB_DIR/medium.src"
echo "sdb"       > "$STUB_DIR/sdb1.pkname"
cat > "$TMP/bin/findmnt" <<'EOF'
#!/bin/bash
case "$*" in
    "-no SOURCE -M /run/live/medium") cat "$STUB_DIR/medium.src" 2>/dev/null ;;
    "-nro SOURCE,FSTYPE")             cat "$STUB_DIR/mounts"     2>/dev/null ;;
    "-no FSTYPE -M /")                cat "$STUB_DIR/rootfstype" 2>/dev/null ;;
esac
exit 0
EOF
chmod +x "$TMP/bin/findmnt"
: > "$TMP/dev/sdf2"; mk_smart sdf2 SN-OTHER ATA 7200
ld=$(CRUCIBLE_LIVE_DIR="$TMP/live-dir" run_admission $'no\n' sdb sdf2)
check "Live 模式：開機碟 sdb 被 BLOCK/BOOT_MEDIUM" \
      "$([ "$(dec "$ld" sdb)" = BLOCK ] && [ "$(rsn "$ld" sdb)" = BOOT_MEDIUM ]; echo $?)"
check "Live 模式：其他碟不受影響，仍可測" "$([ "$(dec "$ld" sdf2)" = ALLOW ]; echo $?)"

# --- Case 7: Live 模式反查失敗 -> 退化為排除全部 removable ---
rm -f "$STUB_DIR/medium.src"
mkdir -p "$TMP/sys/block/sdb" "$TMP/sys/block/sdf2"
echo 1 > "$TMP/sys/block/sdb/removable"
echo 0 > "$TMP/sys/block/sdf2/removable"
ld=$(CRUCIBLE_LIVE_DIR="$TMP/live-dir" run_admission $'no\n' sdb sdf2)
check "反查失敗：removable 碟退化為 BLOCK/REMOVABLE_BOOT_UNKNOWN" \
      "$([ "$(dec "$ld" sdb)" = BLOCK ] && [ "$(rsn "$ld" sdb)" = REMOVABLE_BOOT_UNKNOWN ]; echo $?)"
check "反查失敗：內接碟不受影響 (主要使用情境不能被誤擋)" \
      "$([ "$(dec "$ld" sdf2)" = ALLOW ]; echo $?)"

# --- Case 8: 已安裝環境不啟用 Boot Medium 排除 ---
ld=$(run_admission $'no\n' sdb)
check "已安裝環境：removable 碟不因 Boot Medium 規則被擋" \
      "$([ "$(dec "$ld" sdb)" = ALLOW ]; echo $?)"

echo "-------------------------------"
printf "通過 %d / 失敗 %d\n" "$pass" "$fail"
[ "$fail" -eq 0 ]
