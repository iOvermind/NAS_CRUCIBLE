#!/bin/bash
source "$(dirname "${BASH_SOURCE[0]}")"/../lib/device_probe.sh
# =========================================================================
# M2A-3C: Precheck Adapter (環境、身分與協議防護線)
# =========================================================================
precheck_adapter() {
    local dev=$1
    local expected_serial=$2
    local expected_protocol=$3
    local log_dir=$4
    local ev_file="$log_dir/${expected_serial}_precheck_evidence.json"
    
    local final_rc=0
    local reason="COMPLETED_SUCCESSFULLY"

    # 1. 嚴格的層層遞進檢查
    if [ ! -e "/dev/$dev" ]; then
        final_rc=2; reason="DEVICE_NODE_MISSING"
    elif [ ! -b "/dev/$dev" ]; then
        final_rc=2; reason="NOT_A_BLOCK_DEVICE"
    elif [ ! -e "/sys/class/block/$dev/device" ]; then
        final_rc=2; reason="SYSFS_DEVICE_MISSING"
    else
        # 2. 一次性獲取 Identity JSON (防禦 TOCTOU)
        local identity_json
        identity_json=$(smartctl -j -i "/dev/$dev" 2>/dev/null)
        local smart_rc=$?

        # 檢驗 bit 0, 1, 2 (通訊與指令異常)
        if [ $((smart_rc & 7)) -ne 0 ]; then
            final_rc=2; reason="IDENTITY_READ_COMMAND_FAILED"
        elif ! jq empty <<<"$identity_json" >/dev/null 2>&1; then
            final_rc=2; reason="IDENTITY_JSON_INVALID"
        else
            local cur_serial
            cur_serial=$(jq -r '.serial_number // empty' <<<"$identity_json")
            local cur_protocol
            cur_protocol=$(jq -r '.device.protocol // empty' <<<"$identity_json")
            
            # 3. 身分與協議雙重認證
            if [ "$cur_serial" != "$expected_serial" ]; then
                final_rc=2; reason="IDENTITY_MISMATCH"
            elif [ "$cur_protocol" != "$expected_protocol" ]; then
                final_rc=2; reason="IDENTITY_METADATA_CHANGED"
            else
                # 4. 作業系統 / ZFS / 上層儲存堆疊 深度校驗
                #
                # ZFS 歸屬改用 lib/device_probe.sh 的 dev_in_zpool。原本在這裡
                # 直接把 `zpool status -LP` 的輸出跟整碟路徑做 grep -Fxq 全行
                # 比對：整碟建立的 pool 實際使用的是分割區，zpool 印的是
                # /dev/sdb1 而 target_real 是 /dev/sdb，永遠不會命中 ——
                # 也就是最常見的整碟 pool 情境完全沒有受到保護。
                if lsblk -no MOUNTPOINTS "/dev/$dev" | grep -q "\S" || findmnt "/dev/$dev" >/dev/null 2>&1; then
                    final_rc=2; reason="DEVICE_IS_MOUNTED"
                elif lsblk -f "/dev/$dev" | grep -iq "zfs_member"; then
                    final_rc=2; reason="ACTIVE_ZFS_MEMBER_PARTITION"
                elif dev_has_holders "$dev"; then
                    # LVM PV / mdraid 成員 / 已開啟的 LUKS：碟上有活著的資料，
                    # 但掛載點與 zfs_member 檢查都看不到它們。
                    final_rc=2; reason="DEVICE_HAS_STORAGE_HOLDERS"
                else
                    dev_in_zpool "$dev"
                    case $? in
                        0) final_rc=2; reason="ACTIVE_ZFS_POOL_MEMBER" ;;
                        2) final_rc=2; reason="ZPOOL_STATUS_QUERY_FAILED" ;;
                    esac
                fi
            fi
        fi
    fi

    local ev_status="COMPLETED"
    [ "$final_rc" -eq 2 ] && ev_status="ABORTED"

    # 5. Evidence 寫入雙保險 (寫入失敗直接 RC 2)
    if ! jq -n \
       --arg rc "$final_rc" \
       --arg rsn "$reason" \
       --arg stat "$ev_status" \
       '{
         "adapter": {"name": "precheck", "version": "1.0"},
         "execution": {"status": $stat, "exit_code": ($rc | tonumber), "reason": $rsn}
       }' > "$ev_file" 2>/dev/null; then
        echo "❌ [precheck_adapter] 嚴重錯誤：Evidence 寫入失敗 ($ev_file)"
        return 2
    fi

    return "$final_rc"
}
