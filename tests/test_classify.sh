#!/bin/bash
# =========================================================================
# Device Class 判定與裝置歸屬探測測試
#   誤判的代價不對稱：把 SSD 判成 HDD 會套用 302400 秒的破壞性全碟寫入。
# =========================================================================
set -u
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/lib/device_probe.sh"

pass=0; fail=0
t() { # t <protocol> <rot> <期望>
    local got; got=$(classify_device "$1" "$2")
    if [ "$got" = "$3" ]; then printf "  ✅ %-6s rot=%-7s -> %s\n" "$1" "$2" "$got"; pass=$((pass+1))
    else printf "  ❌ %-6s rot=%-7s -> %s (期望 %s)\n" "$1" "$2" "$got" "$3"; fail=$((fail+1)); fi
}

echo "== classify_device =="
t ATA  0        SATA_SSD
t ATA  7200     SATA_HDD
t ATA  5400     SATA_HDD
t SCSI 0        SAS_SSD
t SCSI 15000    SAS_HDD
t NVMe ABSENT   NVME_SSD
t NVMe 0        NVME_SSD

# 關鍵回歸：舊版 `.rotation_rate == 0` 在欄位缺漏時得到 false，
# 於是 SSD 被歸為 HDD 並吃到破壞性 profile。
t ATA  ABSENT   UNKNOWN
t SCSI ABSENT   UNKNOWN
t SCSI null     UNKNOWN
t ATA  ''       UNKNOWN
t ''   0        UNKNOWN
t SAT  0        UNKNOWN

echo
echo "== jq 取值語意 (0 不可被 // 吞掉) =="
chk() { if [ "$2" = "$3" ]; then printf "  ✅ %s -> %s\n" "$1" "$2"; pass=$((pass+1));
        else printf "  ❌ %s -> %s (期望 %s)\n" "$1" "$2" "$3"; fail=$((fail+1)); fi; }
chk "rotation_rate=0"    "$(jq -rn '{rotation_rate:0} | .rotation_rate // "ABSENT"')" "0"
chk "rotation_rate 缺漏" "$(jq -rn '{} | .rotation_rate // "ABSENT"')" "ABSENT"
chk "舊寫法 ==0 遇缺漏"  "$(jq -rn '{} | .rotation_rate == 0')" "false"

echo
echo "== dev_has_holders =="
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
mkdir -p "$T/class/block/sdx/sdx1/holders/dm-0" \
         "$T/class/block/sdy/holders/md0" \
         "$T/class/block/sdz"
export SYSFS_ROOT="$T"
h() { if dev_has_holders "$1"; then [ "$2" = yes ]; else [ "$2" = no ]; fi
      if [ $? -eq 0 ]; then printf "  ✅ %s (期望 holder=%s)\n" "$1" "$2"; pass=$((pass+1))
      else printf "  ❌ %s (期望 holder=%s)\n" "$1" "$2"; fail=$((fail+1)); fi; }
h sdx yes   # LVM PV 掛在分割區上
h sdy yes   # mdraid 成員, 整碟
h sdz no    # 乾淨的碟

echo "-------------------------------"
printf "通過 %d / 失敗 %d\n" "$pass" "$fail"
[ "$fail" -eq 0 ]
