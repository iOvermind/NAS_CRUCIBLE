#!/bin/bash
# =========================================================================
# M2A-3D: Snapshot Adapter (唯讀快照擷取器 - 帶 Observation 紀錄)
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
    local obs_json="{}"

    # 擷取快照並驗證 JSON
    smartctl -j -x "/dev/$dev" > "$snap_file" 2>/dev/null
    
    if ! jq -e 'has("smartctl") and (.smartctl.exit_status | type == "number")' "$snap_file" >/dev/null 2>&1; then
        final_rc=2
        reason="SNAPSHOT_CAPTURE_FAILED_OR_INVALID"
    else
        local smart_rc
        smart_rc=$(jq -r '.smartctl.exit_status' "$snap_file")
        obs_json="{\"smartctl_exit_status\": $smart_rc}"
        
        # 僅檢查 Bit 0, 1, 2 (通訊與指令異常)
        if [ $((smart_rc & 7)) -ne 0 ]; then
            final_rc=2
            reason="SMARTCTL_SNAPSHOT_COMMAND_FAILED"
        elif [ "$smart_rc" -ne 0 ]; then
            # Bit 3~7 觸發，快照已成功取得，改標記 Flags
            reason="COMPLETED_WITH_SMART_STATUS_FLAGS"
        fi
    fi

    local ev_status="COMPLETED"
    [ "$final_rc" -eq 2 ] && ev_status="ABORTED"

    # Evidence 寫入雙保險
    if ! jq -n \
       --arg rc "$final_rc" \
       --arg rsn "$reason" \
       --arg stat "$ev_status" \
       --argjson obs "$obs_json" \
       '{
         "adapter": {"name": "snapshot", "version": "1.0"},
         "execution": {"status": $stat, "exit_code": ($rc | tonumber), "reason": $rsn},
         "observation": $obs
       }' > "$ev_file" 2>/dev/null; then
        echo "❌ [snapshot_adapter] 嚴重錯誤：Evidence 寫入失敗 ($ev_file)"
        return 2
    fi

    return "$final_rc"
}
