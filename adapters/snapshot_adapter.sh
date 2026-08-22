#!/bin/bash
# =========================================================================
# M2A-3D: Snapshot Adapter (唯讀快照擷取器 - Bitmask 精準放行)
# =========================================================================
snapshot_adapter() {
    local dev=$1
    local serial=$2
    local log_dir=$3
    local phase_name=$4
    
    local snap_file="$log_dir/${serial}_${phase_name}.json"
    local ev_file="$log_dir/${serial}_${phase_name}_evidence.json"
    
    local final_rc=0
    local reason="COMPLETED_SUCCESSFULLY"

    # 擷取快照並驗證 JSON
    smartctl -j -x "/dev/$dev" > "$snap_file" 2>/dev/null
    
    if ! jq -e 'has("smartctl") and (.smartctl.exit_status | type == "number")' "$snap_file" >/dev/null 2>&1; then
        final_rc=2
        reason="SNAPSHOT_CAPTURE_FAILED_OR_INVALID"
    else
        local smart_rc
        smart_rc=$(jq -r '.smartctl.exit_status' "$snap_file")
        
        # 解析 Bitmask：僅檢查 Bit 0, 1, 2 (Mask 7 -> 0x07) 是否觸發
        # 0x01: Parse failure | 0x02: Device open failure | 0x04: SMART command failure
        if [ $((smart_rc & 7)) -ne 0 ]; then
            final_rc=2
            reason="SMARTCTL_SNAPSHOT_COMMAND_FAILED"
        elif [ "$smart_rc" -ne 0 ]; then
            # Bit 3~7 觸發 (有錯誤紀錄等)，Snapshot 本身仍算成功 (RC 0)
            reason="COMPLETED_WITH_SMART_WARNINGS"
        fi
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
