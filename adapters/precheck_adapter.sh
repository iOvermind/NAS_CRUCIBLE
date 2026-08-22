#!/bin/bash
# =========================================================================
# M2A-3C: Precheck Adapter (環境與身分防護線)
# =========================================================================
precheck_adapter() {
    local dev=$1
    local serial=$2
    local log_dir=$3
    local ev_file="$log_dir/${serial}_precheck_evidence.json"
    
    local final_rc=0
    local reason="COMPLETED_SUCCESSFULLY"

    # 嚴格的 7 層檢查順序 (層層遞進的 Fail-Closed)
    if [ ! -e "/dev/$dev" ]; then
        final_rc=2; reason="DEVICE_NODE_MISSING"
    elif [ ! -b "/dev/$dev" ]; then
        final_rc=2; reason="NOT_A_BLOCK_DEVICE"
    elif [ ! -e "/sys/class/block/$dev/device" ]; then
        final_rc=2; reason="SYSFS_DEVICE_MISSING"
    elif ! smartctl -j -i "/dev/$dev" >/dev/null 2>&1; then
        final_rc=2; reason="IDENTITY_UNREADABLE"
    else
        local cur_serial
        cur_serial=$(smartctl -j -i "/dev/$dev" | jq -r '.serial_number // empty')
        
        if [ "$cur_serial" != "$serial" ]; then
            final_rc=2; reason="IDENTITY_MISMATCH"
        elif lsblk -no MOUNTPOINTS "/dev/$dev" | grep -q "\S" || findmnt "/dev/$dev" >/dev/null 2>&1; then
            final_rc=2; reason="DEVICE_IS_MOUNTED"
        elif lsblk -f "/dev/$dev" | grep -iq "zfs_member" || zpool status -LP 2>/dev/null | grep -qE "/dev/$dev\b"; then
            final_rc=2; reason="ACTIVE_ZFS_MEMBER"
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
