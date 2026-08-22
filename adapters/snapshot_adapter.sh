#!/bin/bash
# =========================================================================
# M2A-3D: Snapshot Adapter (唯讀快照擷取器)
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

    smartctl -j -x "/dev/$dev" > "$snap_file" 2>/dev/null
    
    # 嚴格驗證快照 JSON 是否合法，且 exit_status 必須存在
    if ! jq -e 'has("smartctl") and (.smartctl.exit_status | type == "number")' "$snap_file" >/dev/null 2>&1; then
        final_rc=2
        reason="SNAPSHOT_CAPTURE_FAILED_OR_INVALID"
    else
        local smart_rc
        smart_rc=$(jq -r '.smartctl.exit_status' "$snap_file")
        
        # 只要 smartctl 指令不為 0，一律視為取得證據失敗 (RC 2)
        # 註: 若是二手盤本身有 SMART Error (例如 bit 3/4)，這裡直接回傳 RC 2 非常合理，
        # 因為「連 Baseline 都會噴錯的盤」根本不該進入 destructive workload。
        if [ "$smart_rc" -ne 0 ]; then
            final_rc=2
            reason="SMARTCTL_SNAPSHOT_COMMAND_FAILED"
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
