#!/bin/bash
# =========================================================================
# Device Probe Library
# =========================================================================

is_device_accessible() {
    local dev=$1
    # 1. Block device exists
    [ -b "/dev/$dev" ] || return 1
    # 2. Sysfs node exists
    [ -e "/sys/class/block/$dev/device" ] || return 1
    # 3. smartctl can communicate
    smartctl -i "/dev/$dev" >/dev/null 2>&1 || return 1
    return 0 
}

# -------------------------------------------------------------------------
# ZFS pool 歸屬判定
#   回傳 0 = 屬於已匯入的 pool
#        1 = 確定不屬於
#        2 = 無法判定 (zpool 可用但查詢失敗) -> 呼叫端必須 Fail-Closed
#
# 為什麼不能直接字串比對 zpool status 的輸出：
#   在整碟建立的 pool，ZFS 實際使用的是分割區。`zpool status -LP` 印出
#   /dev/sdb1，而我們手上的 target 是整碟 /dev/sdb，`grep -Fxq` 這種
#   全行精確比對永遠不會命中 —— 也就是最常見的「整碟 pool」情境完全沒有
#   受到保護。這裡額外用 PKNAME 往上追一層母裝置。
# -------------------------------------------------------------------------
dev_in_zpool() {
    local dev=$1 target
    target=$(readlink -f "/dev/$dev") || return 2

    # zpool 指令不存在 => 系統上不可能有已匯入的 pool。
    # 這不是「查詢失敗」，不該讓 live/救援環境下的每一顆碟都被擋下。
    command -v zpool >/dev/null 2>&1 || return 1

    local out rc
    out=$(zpool status -LP 2>/dev/null); rc=$?
    [ "$rc" -eq 0 ] || return 2

    local p pk
    while read -r p; do
        [ -b "$p" ] || continue
        p=$(readlink -f "$p")
        [ "$p" = "$target" ] && return 0
        pk=$(lsblk -no PKNAME "$p" 2>/dev/null | head -1)
        [ -n "$pk" ] && [ "/dev/$pk" = "$target" ] && return 0
    done < <(printf '%s\n' "$out" | awk '{print $1}' | grep '^/dev/' || true)
    return 1
}

# -------------------------------------------------------------------------
# 是否被上層儲存堆疊佔用 (LVM PV / mdraid 成員 / 已開啟的 LUKS)
#   ZFS 之外的這些情境同樣代表「碟上有活著的資料」，但既有的掛載點與
#   zfs_member 檢查完全看不到它們。
# -------------------------------------------------------------------------
# SYSFS_ROOT 是測試接縫，正式執行一律是 /sys。
dev_has_holders() {
    local dev=$1 h
    local root=${SYSFS_ROOT:-/sys}
    for h in "$root/class/block/$dev/holders/"* "$root/class/block/$dev/$dev"*"/holders/"*; do
        [ -e "$h" ] && return 0
    done
    return 1
}

# -------------------------------------------------------------------------
# 依協議與 rotation_rate 判定 Device Class
#   classify_device <protocol> <rotation_rate|ABSENT>
#
# 這段邏輯原本在 crucible.sh 的 TUI 與 preflight 各寫了一份，同一個
# 誤判 bug 因此出現兩次。抽成單一來源，並由 tests/test_classify.sh 鎖住。
#
# rotation_rate 缺漏時一律回 UNKNOWN。絕不可預設成 HDD ——
# 那會對一顆不確定是不是 SSD 的碟套用 302400 秒的破壞性全碟寫入。
# 注意 jq 裡 0 是真值，取值要用 `.rotation_rate // "ABSENT"` 才能區分
# 「值為 0」與「欄位不存在」；用 `.rotation_rate == 0` 會讓缺漏變成 false。
# -------------------------------------------------------------------------
classify_device() {
    local protocol=$1 rot=$2
    case "$protocol" in
        NVMe) echo "NVME_SSD"; return 0 ;;
        ATA|SCSI) ;;
        *) echo "UNKNOWN"; return 0 ;;
    esac
    case "$rot" in
        ''|ABSENT|null) echo "UNKNOWN"; return 0 ;;
    esac
    if [ "$rot" = "0" ]; then
        [ "$protocol" = "ATA" ] && echo "SATA_SSD" || echo "SAS_SSD"
    else
        [ "$protocol" = "ATA" ] && echo "SATA_HDD" || echo "SAS_HDD"
    fi
}

# -------------------------------------------------------------------------
# 碟上是否存在 Signature (檔案系統或儲存堆疊成員標記)
#   回傳 0 = 有簽章 (這顆碟曾被寫入資料)
#        1 = 沒有任何簽章 (可視為空白碟)
#        2 = 無法判定 -> 呼叫端必須 Fail-Closed
#
# 為什麼需要這一條，而既有的掛載 / zpool / holders 三項不夠：
#   那三項判斷的全都是「執行時狀態」。Live Image 開機時主系統沒有啟動，
#   沒有東西被掛載、沒有 pool 被匯入、沒有 md/LVM 被組裝 —— 三道防線同時
#   歸零，一顆正在服役的 NAS 資料碟看起來會跟一顆全新空碟一模一樣，然後
#   badblocks -wsv 抹下去。Signature 讀的是碟上的靜態事實，不依賴任何執行
#   時狀態，因此在 Live 與已安裝環境下行為一致。見 docs/adr/0001。
#
# FSTYPE 涵蓋檔案系統本身與 zfs_member / LVM2_member / linux_raid_member /
# crypto_LUKS 這類成員標記；PTTYPE 補上「只有分割表、還沒建檔案系統」的碟。
# 查詢對象是整碟，lsblk 會一併列出其下所有分割區。
# -------------------------------------------------------------------------
dev_has_signature() {
    local dev=$1 out name fstype pttype found=1
    out=$(lsblk -rno NAME,FSTYPE,PTTYPE "/dev/$dev" 2>/dev/null) || return 2
    # 連裝置自己那一行都沒有，代表 lsblk 根本沒認得這個裝置 —— 不是「乾淨」。
    [ -n "$out" ] || return 2
    while read -r name fstype pttype; do
        [ -n "$name" ] || continue
        if [ -n "$fstype" ] || [ -n "$pttype" ]; then found=0; fi
    done <<<"$out"
    return "$found"
}

# -------------------------------------------------------------------------
# 是否為可移除 / USB 裝置
#   僅在 Live 模式下反查不到 Boot Medium 時，作為保守退化規則使用。
# -------------------------------------------------------------------------
dev_is_removable() {
    local dev=$1 root=${SYSFS_ROOT:-/sys} tran
    [ "$(cat "$root/block/$dev/removable" 2>/dev/null)" = "1" ] && return 0
    tran=$(lsblk -dnro TRAN "/dev/$dev" 2>/dev/null | head -1)
    [ "$tran" = "usb" ] && return 0
    return 1
}

# -------------------------------------------------------------------------
# 是否正跑在 Live Image 之中
#   Live 與已安裝環境的差別不只是「在哪開機」：Live 之下開機媒體本身也是一顆
#   block device，會出現在受測清單裡。這個判斷決定要不要啟用 Boot Medium 排除。
# -------------------------------------------------------------------------
is_live_environment() {
    [ -d "${CRUCIBLE_LIVE_DIR:-/run/live}" ] && return 0
    grep -qw 'boot=live' "${CRUCIBLE_CMDLINE_FILE:-/proc/cmdline}" 2>/dev/null && return 0
    [ "$(findmnt -no FSTYPE -M / 2>/dev/null)" = "overlay" ] && return 0
    return 1
}

# -------------------------------------------------------------------------
# 反查 Boot Medium：承載 Live Image、系統當下正由它開機的那一顆實體碟
#   成功時印出裝置名稱 (如 sda) 並回傳 0；反查不到回傳 1，呼叫端必須退化為
#   「排除全部 removable 裝置」的保守規則，絕不可當成「沒有開機碟」。
#
# 印出的是整顆碟而非分割區：ISO 分割區與其後的 Evidence Store 分區都在同一
# 顆碟上，抹掉整碟等於連自己跑到一半的證據一起銷毀。
# -------------------------------------------------------------------------
detect_boot_medium() {
    local root=${SYSFS_ROOT:-/sys} mp src backing disk
    for mp in /run/live/medium /run/live/findiso /lib/live/mount/medium /cdrom /media/cdrom; do
        src=$(findmnt -no SOURCE -M "$mp" 2>/dev/null | head -1)
        [ -n "$src" ] && break
    done
    # 退路：任何掛載中的 iso9660 檔案系統都只可能來自開機媒體。
    if [ -z "$src" ]; then
        src=$(findmnt -nro SOURCE,FSTYPE 2>/dev/null | awk '$2=="iso9660"{print $1; exit}')
    fi
    [ -n "$src" ] || return 1

    # toram / findiso 這類情境下掛的是 loop 裝置，要往回追到承載映像的實體分割區。
    case "$src" in
        /dev/loop*)
            backing=$(cat "$root/block/${src#/dev/}/loop/backing_file" 2>/dev/null)
            backing=${backing% (deleted)}
            [ -n "$backing" ] || return 1
            src=$(findmnt -no SOURCE -T "$backing" 2>/dev/null | head -1)
            [ -n "$src" ] || return 1
            ;;
    esac

    disk=$(lsblk -no PKNAME "$src" 2>/dev/null | head -1)
    [ -n "$disk" ] || disk=$(basename "$src")
    [ -n "$disk" ] || return 1
    printf '%s\n' "$disk"
    return 0
}
