#!/bin/bash
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
        # 2. 一次性獲取 Identity，防禦 TOCTOU
        local identity_json
        identity_json=$(smartctl -j -i "/dev/$dev" 2>/dev/null)
        local smart_rc=$?

        # 檢驗 bit 0, 1, 2
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
                # 4. 作業系統與 ZFS 掛載深度校驗
                local target_real
                target_real=$(readlink -f "/dev/$dev")

                if lsblk -no MOUNTPOINTS "/dev/$dev" | grep -q "\S" || findmnt "/dev/$dev" >/dev/null 2>&1; then
                    final_rc=2; reason="DEVICE_IS_MOUNTED"
                elif lsblk -f "/dev/$dev" | grep -iq "zfs_member"; then
                    final_rc=2; reason="ACTIVE_ZFS_MEMBER_PARTITION"
                # zpool status -LP 輸出第一欄即為裝置路徑，用 awk 取出比對
                elif zpool status -LP 2>/dev/null | awk '{print $1}' | grep -Fxq "$target_real"; then
                    final_rc=2; reason="ACTIVE_ZFS_POOL_MEMBER"
                fi
            fi
        fi
    fi

    local ev_status="COMPLETED"
    [ "$final_rc" -eq 2 ] && ev_status="ABORTED"

    jq -n \
       --arg rc "$final_rc" \
       --arg rsn "$reason" \
       --arg stat "$ev_status" \
       '{
         "adapter": {"name": "precheck", "version": "1.0"},
         "execution": {"status": $stat, "exit_code": $rc, "reason": $rsn}
       }' > "$ev_file"

    return "$final_rc"
}
