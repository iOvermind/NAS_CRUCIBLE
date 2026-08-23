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
