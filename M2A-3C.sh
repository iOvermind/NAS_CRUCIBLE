# =========================================================
# 📦 M2A-3C: Precheck Adapter (環境與身分防護線)
# =========================================================
precheck_adapter() {
    local dev=$1
    local serial=$2
    local log_dir=$3
    local ev_file="$log_dir/${serial}_precheck_evidence.json"
    
    local final_rc=0
    local reason="COMPLETED_SUCCESSFULLY"

    # 1. 實體身分再確認 (TOCTOU 防護)
    local cur_serial
    cur_serial=$(smartctl -j -i "/dev/$dev" 2>/dev/null | jq -r '.serial_number // empty')
    
    if [ "$cur_serial" != "$serial" ]; then
        final_rc=2
        reason="IDENTITY_MISMATCH"
    # 2. 區塊裝置確認
    elif [ ! -b "/dev/$dev" ]; then
        final_rc=2
        reason="NOT_A_BLOCK_DEVICE"
    # 3. 作業系統掛載確認
    elif lsblk -no MOUNTPOINTS "/dev/$dev" | grep -q "\S" || findmnt "/dev/$dev" >/dev/null 2>&1; then
        final_rc=2
        reason="DEVICE_IS_MOUNTED"
    # 4. 活躍 ZFS Pool 確認
    elif lsblk -f "/dev/$dev" | grep -iq "zfs_member" || zpool status -P 2>/dev/null | grep -qE "/dev/$dev\b"; then
        final_rc=2
        reason="ACTIVE_ZFS_MEMBER"
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

# =========================================================
# 📦 M2A-3D: Snapshot Adapter (唯讀快照擷取器)
# =========================================================
snapshot_adapter() {
    local dev=$1
    local serial=$2
    local log_dir=$3
    local phase_name=$4 # baseline_snapshot 或是 final_snapshot
    
    local snap_file="$log_dir/${serial}_${phase_name}.json"
    local ev_file="$log_dir/${serial}_${phase_name}_evidence.json"
    
    local final_rc=0
    local reason="COMPLETED_SUCCESSFULLY"

    # 擷取快照並驗證 JSON (不判斷硬碟死活，只判斷快照是否成功存檔)
    smartctl -j -x "/dev/$dev" > "$snap_file" 2>/dev/null
    
    if ! jq empty "$snap_file" >/dev/null 2>&1; then
        final_rc=2
        reason="SNAPSHOT_CAPTURE_FAILED_OR_INVALID"
    fi

    local ev_status="COMPLETED"
    [ "$final_rc" -eq 2 ] && ev_status="ABORTED"

    jq -n \
       --arg rc "$final_rc" \
       --arg rsn "$reason" \
       --arg stat "$ev_status" \
       '{
         "adapter": {"name": "snapshot", "version": "1.0"},
         "execution": {"status": $stat, "exit_code": $rc, "reason": $rsn}
       }' > "$ev_file"

    return "$final_rc"
}
