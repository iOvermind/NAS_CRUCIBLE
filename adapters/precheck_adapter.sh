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
                # 4. 作業系統與 ZFS 掛載深度校驗
                local target_real
                target_real=$(readlink -f "/dev/$dev")

                local zpool_out
                local zpool_rc
                zpool_out=$(zpool status -LP 2>/dev/null)
                zpool_rc=$?

                if lsblk -no MOUNTPOINTS "/dev/$dev" | grep -q "\S" || findmnt "/dev/$dev" >/dev/null 2>&1; then
                    final_rc=2; reason="DEVICE_IS_MOUNTED"
                elif lsblk -f "/dev/$dev" | grep -iq "zfs_member"; then
                    final_rc=2; reason="ACTIVE_ZFS_MEMBER_PARTITION"
                elif [ "$zpool_rc" -ne 0 ]; then
                    # zpool 指令失敗，無法證明硬碟不在 Pool 內，立即 RC 2 攔截！
                    final_rc=2; reason="ZPOOL_STATUS_QUERY_FAILED"
                elif printf '%s\n' "$zpool_out" | awk '{print $1}' | grep -Fxq "$target_real"; then
                    final_rc=2; reason="ACTIVE_ZFS_POOL_MEMBER"
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
