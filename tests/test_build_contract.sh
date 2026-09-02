#!/bin/bash
# =========================================================================
# build/ 層的靜態合約檢查 (不實際建置)
#
# 建一次 ISO 要十幾分鐘，而「漏裝一個套件」「少了一條開機路徑」這類錯誤
# 全都能在幾毫秒內看出來。真的要開機驗證是 tests/run_iso.sh (M3) 的事。
# =========================================================================
set -u
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
B="$ROOT/build"

pass=0; fail=0
check() { if [ "$2" = 0 ]; then printf "  ✅ %s\n" "$1"; pass=$((pass+1))
          else printf "  ❌ %s\n" "$1"; fail=$((fail+1)); fi; }
has()  { grep -q -- "$2" "$1" 2>/dev/null; }

echo "== 檔案齊備 =="
for f in Dockerfile build_iso.sh in_container/build.sh in_container/packages.list \
         boot/grub.cfg boot/isolinux.cfg \
         rootfs/usr/local/sbin/crucible-evidence-store \
         rootfs/usr/local/sbin/crucible-autostart \
         rootfs/etc/systemd/system/crucible-evidence-store.service \
         "rootfs/etc/systemd/system/getty@tty1.service.d/autologin.conf"; do
    check "build/$f" "$([ -f "$B/$f" ]; echo $?)"
done
for f in build_iso.sh in_container/build.sh \
         rootfs/usr/local/sbin/crucible-evidence-store \
         rootfs/usr/local/sbin/crucible-autostart; do
    check "build/$f 可執行" "$([ -x "$B/$f" ]; echo $?)"
done

echo
echo "== 套件清單涵蓋所有執行期依賴 =="
# 少了任何一項，ISO 都會在實機上才炸開。對照 DEVELOPER.md §2。
# procps 與 fdisk 是 QEMU 端到端測試抓到的漏網之魚：
#   - crucible_controller.sh 開頭檢查 ps，缺了它整個工具在 ISO 裡直接 exit 2
#   - Debian 13 把 sfdisk 從 util-linux 拆到 fdisk 套件
for p in smartmontools e2fsprogs nvme-cli jq whiptail util-linux tmux procps \
         linux-image-amd64 live-boot \
         shim-signed grub-efi-amd64-signed isolinux \
         fbterm fonts-wqy-zenhei \
         fdisk dosfstools; do
    check "packages.list 含 $p" \
      "$(grep -qxF "$p" "$B/in_container/packages.list"; echo $?)"
done

echo
echo "== BIOS 與 UEFI 兩條開機路徑 =="
# boot=live 少了的話 live-boot 不會掛 squashfs，is_live_environment 也認不出自己在 Live 中。
check "grub.cfg (UEFI) 帶 boot=live"      "$(has "$B/boot/grub.cfg" 'boot=live'; echo $?)"
check "isolinux.cfg (BIOS) 帶 boot=live"  "$(has "$B/boot/isolinux.cfg" 'boot=live'; echo $?)"
check "grub.cfg 有 nomodeset 相容模式 (fbterm 起不來時的退路)" \
      "$(has "$B/boot/grub.cfg" 'nomodeset'; echo $?)"
# 序列埠 console 是伺服器透過 BMC redirection 觀察開機過程的唯一途徑，
# tests/run_iso.sh 也靠它驗證開機路徑。少了它，M3 完全沒辦法觀察 VM 內部。
check "grub.cfg 帶序列埠 console"     "$(has "$B/boot/grub.cfg" 'console=ttyS0'; echo $?)"
check "isolinux.cfg 帶序列埠 console" "$(has "$B/boot/isolinux.cfg" 'console=ttyS0'; echo $?)"
check "build.sh 掛 BIOS El Torito 開機映像"     "$(has "$B/in_container/build.sh" '-eltorito-boot'; echo $?)"
check "build.sh 掛 UEFI El Torito 開機映像"     "$(has "$B/in_container/build.sh" '-eltorito-alt-boot'; echo $?)"
check "build.sh 產生 isohybrid MBR (dd 到隨身碟後 BIOS 可開機)" \
      "$(has "$B/in_container/build.sh" '-isohybrid-mbr'; echo $?)"
check "build.sh 產生 isohybrid GPT (dd 到隨身碟後 UEFI 可開機，且尾端可加分區)" \
      "$(has "$B/in_container/build.sh" '-isohybrid-gpt-basdat'; echo $?)"

echo
echo "== Secure Boot 開機鏈 =="
# 自編或未簽章的 EFI 執行檔會讓開著 SB 的機器直接拒絕開機。見 docs/adr/0002。
check "BOOTX64.EFI 來自 Debian 官方簽章的 shim" \
      "$(grep -E 'shimx64\.efi\.signed.*BOOTX64\.EFI' "$B/in_container/build.sh" >/dev/null; echo $?)"
check "grub 使用官方簽章版 grubx64.efi.signed" \
      "$(has "$B/in_container/build.sh" 'grubx64.efi.signed'; echo $?)"
check "附上 mmx64 (MOK Manager)" "$(has "$B/in_container/build.sh" 'mmx64'; echo $?)"
check "簽章 grub 的 prefix /EFI/debian 有放設定檔" \
      "$(has "$B/in_container/build.sh" 'EFI/debian'; echo $?)"
check "EFI 樹同時放進 ISO 檔案系統 (部分韌體只掃 ISO9660 的 /EFI/BOOT)" \
      "$(grep -q 'cp -a "\$WORK/efi/EFI" "\$ISO_TREE/EFI"' "$B/in_container/build.sh"; echo $?)"

echo
echo "== 可追溯性 =="
check "build_iso.sh 以 git archive HEAD 取程式碼" \
      "$(has "$B/build_iso.sh" 'git archive --format=tar HEAD'; echo $?)"
check "build_iso.sh 預設拒絕 dirty working tree" \
      "$(has "$B/build_iso.sh" '拒絕建置'; echo $?)"
check "build_iso.sh 提供 --allow-dirty 逃生口" \
      "$(has "$B/build_iso.sh" -- '--allow-dirty'; echo $?)"
check "build.sh 寫出 build_info.json"      "$(has "$B/in_container/build.sh" 'build_info.json'; echo $?)"
check "build_info.json 含 commit"          "$(has "$B/in_container/build.sh" '"commit":'; echo $?)"
check "ISO 附 sha256"                       "$(has "$B/build_iso.sh" 'sha256\|--out' && has "$B/in_container/build.sh" 'sha256sum'; echo $?)"

echo
echo "== 容器建置環境 =="
check "Dockerfile 基於 debian:stable"  "$(has "$B/Dockerfile" 'FROM debian:stable'; echo $?)"
for c in "in_container/ /build/" "rootfs/ /build/rootfs/" "boot/ /build/boot/"; do
    check "Dockerfile COPY $c (build.sh 在容器內讀得到)" \
          "$(grep -qF "COPY $c" "$B/Dockerfile"; echo $?)"
done
for t in debootstrap squashfs-tools xorriso mtools dosfstools; do
    check "容器安裝 $t" "$(has "$B/Dockerfile" "$t"; echo $?)"
done
check "宿主只需 docker 與 git" \
      "$(grep -qE 'for cmd in docker git' "$B/build_iso.sh"; echo $?)"

echo
echo "== Evidence Store 的安全性質 =="
ES="$B/rootfs/usr/local/sbin/crucible-evidence-store"
check "只對 detect_boot_medium 反查到的碟動手" "$(has "$ES" 'detect_boot_medium'; echo $?)"
check "反查失敗時不寫任何分區表 (降級為 RAM)" \
      "$(grep -A1 'detect_boot_medium' "$ES" | grep -q 'fallback_to_ram'; echo $?)"
# 每一個會改寫磁碟的指令，目標都必須是由 $disk 反查出來的變數。
bad=0
while IFS= read -r line; do
    case "$line" in
        *'"$disk"'*|*'"$data_part"'*|*'"$rpt_part"'*) ;;
        *) bad=1; echo "      可疑的寫入目標: $line" ;;
    esac
done < <(grep -nE '(sfdisk|sgdisk|mkfs\.[a-z0-9]+) ' "$ES" | grep -vE '^[0-9]+:\s*#|command -v|for cmd in')
check "所有 sfdisk / mkfs 的目標都來自反查到的開機碟" "$bad"
# gdisk 讀不了 isohybrid 的分割表 (MBR 第一個分割區 type=0x00)，這是實測結論，
# 不要再換回去。
check "不使用 sgdisk 分割開機媒體" \
      "$(! grep -qE '^\s*sgdisk ' "$ES"; echo $?)"
check "格式化前確認分區真的出現在核心中" "$(has "$ES" '[ -b "${data_part:-}" ]'; echo $?)"
check "尾端空間不足時降級而非硬幹" "$(has "$ES" 'MIN_FREE_MB'; echo $?)"
check "Evidence 分區用 ext4 (3-5 天連續寫入需要 journaling)" \
      "$(has "$ES" 'mkfs.ext4'; echo $?)"
check "摘要分區用 FAT32 (插到任何電腦都讀得到)" "$(has "$ES" 'mkfs.vfat'; echo $?)"
check "摘要分區失敗不得影響 Evidence 保存" \
      "$(grep -q '不影響 Evidence 保存' "$ES"; echo $?)"

echo
echo "== 開機流程 =="
AL="$B/rootfs/etc/systemd/system/getty@tty1.service.d/autologin.conf"
AS="$B/rootfs/usr/local/sbin/crucible-autostart"
UNIT="$B/rootfs/etc/systemd/system/crucible-evidence-store.service"
check "tty1 自動登入後進 crucible-autostart" "$(has "$AL" 'crucible-autostart'; echo $?)"
check "Evidence Store 必須早於 tty1 起來"     "$(has "$UNIT" 'Before=getty@tty1.service'; echo $?)"
check "autostart 走 fbterm (中文顯示)"        "$(has "$AS" 'fbterm'; echo $?)"
check "序列埠也自動登入 (BMC redirection 與 run_iso.sh 都需要)" \
      "$([ -f "$B/rootfs/etc/systemd/system/serial-getty@ttyS0.service.d/autologin.conf" ]; echo $?)"
check "fbterm 不可用時退回純 tty"             "$(has "$AS" '/dev/fb0'; echo $?)"
check "autostart 在 tmux 內執行 crucible.sh"  "$(has "$AS" 'tmux new-session'; echo $?)"
# 這一條最容易漏：不指定的話 crucible.sh 會把 log 寫進 live rootfs (RAM)，
# Evidence Store 白建了。
check "autostart 把 CRUCIBLE_LOG_DIR 指到 Evidence Store" \
      "$(grep -q 'export CRUCIBLE_LOG_DIR="\$DATA_MNT' "$AS"; echo $?)"
check "autostart 把 CRUCIBLE_REPORT_DIR 指到摘要分區" \
      "$(grep -q 'export CRUCIBLE_REPORT_DIR="\$RPT_MNT' "$AS"; echo $?)"

echo
echo "== No-Persistence 旗標三方一致 =="
# 三支腳本各自寫死不同路徑的話，警告永遠不會出現，操作員會以為證據都在。
FLAG='/run/crucible/no-persistence'
check "evidence-store 寫入 $FLAG"  "$(has "$ES" "$FLAG"; echo $?)"
check "autostart 讀取 $FLAG"       "$(has "$AS" "$FLAG"; echo $?)"
check "crucible.sh 讀取 $FLAG"     "$(has "$ROOT/crucible.sh" "$FLAG"; echo $?)"
check "三支腳本使用同一個覆寫用環境變數 CRUCIBLE_NOPERSIST_FLAG" \
      "$(has "$ES" "CRUCIBLE_NOPERSIST_FLAG" && has "$AS" "CRUCIBLE_NOPERSIST_FLAG" && has "$ROOT/crucible.sh" "CRUCIBLE_NOPERSIST_FLAG"; echo $?)"
check "crucible.sh 在確認前再警告一次" \
      "$(grep -B2 '確定抹除請輸入 YES' "$ROOT/crucible.sh" | grep -q 'persistence_banner'; echo $?)"

echo "-------------------------------"
printf "通過 %d / 失敗 %d\n" "$pass" "$fail"
[ "$fail" -eq 0 ]
