#!/bin/bash
# =========================================================================
# 模組: HDD Runner (獨立 Process, 嚴格狀態守衛與實體 Adapter 調用)
# =========================================================================

# 1. Runner 自身參數防禦 (Defense in Depth)
if [ "$#" -ne 6 ]; then
    echo "❌ [Runner] INVALID_RUNNER_ARGUMENTS: Expected 6, got $#"
    exit 2
fi

SERIAL=$1
DEV=$2
PROFILE=$3
POL_NAME=$4
POL_VER=$5
PROTOCOL=$6

if [ "$PROFILE" != "HDD_FULL_BURNIN" ]; then
    echo "❌ [Runner $SERIAL] PROFILE_MISMATCH: Expected HDD_FULL_BURNIN, got $PROFILE"
    exit 2
fi

case "$PROTOCOL" in
    ATA|SCSI) ;;
    *)
        echo "❌ [Runner $SERIAL] UNSUPPORTED_PROTOCOL: $PROTOCOL"
        exit 2
        ;;
esac

# 2. 環境與目錄設定 (絕對路徑化)
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
LOG_DIR="$SCRIPT_DIR/logs"
EXEC_FILE="$LOG_DIR/exec_record_${SERIAL}.json"
mkdir -p "$LOG_DIR"

# 3. 引入真實 Adapter
source "$SCRIPT_DIR/adapters/precheck_adapter.sh"
source "$SCRIPT_DIR/adapters/snapshot_adapter.sh"
source "$SCRIPT_DIR/adapters/smartctl_long_adapter.sh"
source "$SCRIPT_DIR/adapters/badblocks_adapter.sh"

# =========================================================
# 📦 Runner 狀態機與守衛
# =========================================================
jq -n \
   --arg sn "$SERIAL" \
   --arg prof "$PROFILE" \
   --arg pn "$POL_NAME" \
   --arg pv "$POL_VER" \
   '{
     "serial": $sn,
     "execution": {
       "profile": $prof,
       "policy": { "name": $pn, "version": $pv },
       "status": "STARTING",
       "current_phase": "none",
       "phases": {
         "precheck": { "status": "PENDING" },
         "baseline_snapshot": { "status": "PENDING" },
         "smart_long_1": { "status": "PENDING" },
         "badblocks": { "status": "PENDING" },
         "smart_long_2": { "status": "PENDING" },
         "final_snapshot": { "status": "PENDING" }
       }
     }
   }' > "$EXEC_FILE"

update_phase_state() {
    local p=$1
    local new_st=$2
    local ec=${3:-0}
    local rsn=${4:-""}
    
    local curr_st
    curr_st=$(jq -r --arg p "$p" '.execution.phases[$p].status // "PHASE_NOT_FOUND"' "$EXEC_FILE")

    if [ "$curr_st" == "PHASE_NOT_FOUND" ]; then exit 2; fi

    local valid=false
    if [ "$curr_st" == "PENDING" ] && [[ "$new_st" =~ ^(RUNNING|SKIPPED)$ ]]; then valid=true; fi
    if [ "$curr_st" == "RUNNING" ] && [[ "$new_st" =~ ^(PASS|FAIL|ABORTED|INTERRUPTED)$ ]]; then valid=true; fi
    [ "$valid" != "true" ] && exit 2

    if [ "$new_st" == "RUNNING" ]; then
        jq --arg p "$p" --arg st "$new_st" \
           '.execution.current_phase = $p | .execution.phases[$p].status = $st' \
           "$EXEC_FILE" > "${EXEC_FILE}.tmp" && mv "${EXEC_FILE}.tmp" "$EXEC_FILE"
    else
        jq --arg p "$p" --arg st "$new_st" --argjson ec "$ec" --arg rsn "$rsn" \
           '.execution.phases[$p] = {status: $st, exit_code: $ec, reason: $rsn}' \
           "$EXEC_FILE" > "${EXEC_FILE}.tmp" && mv "${EXEC_FILE}.tmp" "$EXEC_FILE"
    fi
}

trap 'handle_interrupt 143' TERM
trap 'handle_interrupt 130' INT

handle_interrupt() {
    local sig_rc=$1
    local curr_phase
    curr_phase=$(jq -r '.execution.current_phase' "$EXEC_FILE")

    if [ "$curr_phase" != "none" ] && [ "$curr_phase" != "null" ]; then
        update_phase_state "$curr_phase" "INTERRUPTED" "$sig_rc" "GLOBAL_ABORT_INFRASTRUCTURE_FAILURE"
    fi

    for p in "precheck" "baseline_snapshot" "smart_long_1" "badblocks" "smart_long_2" "final_snapshot"; do
        local st
        st=$(jq -r --arg p "$p" '.execution.phases[$p].status // "UNKNOWN"' "$EXEC_FILE")
        if [ "$st" == "PENDING" ]; then
            update_phase_state "$p" "SKIPPED" 0 "CASCADED_FROM_GLOBAL_ABORT"
        fi
    done

    jq '.execution.status = "INTERRUPTED" | .execution.current_phase = "none"' "$EXEC_FILE" > "${EXEC_FILE}.tmp" && mv "${EXEC_FILE}.tmp" "$EXEC_FILE"
    exit "$sig_rc"
}

# =========================================================
# ⚙️ 執行器 (呼叫真實 Adapter 與契約警察)
# =========================================================
run_phase() {
    local phase=$1
    update_phase_state "$phase" "RUNNING"
    
    local rc=2
    case "$phase" in
        "precheck")
            precheck_adapter "$DEV" "$SERIAL" "$LOG_DIR"
            rc=$?
            ;;
        "baseline_snapshot"|"final_snapshot")
            snapshot_adapter "$DEV" "$SERIAL" "$LOG_DIR" "$phase"
            rc=$?
            ;;
        "smart_long_1"|"smart_long_2")
            smartctl_long_adapter "$DEV" "$SERIAL" "$PROTOCOL" "$LOG_DIR" 86400
            rc=$?
            ;;
        "badblocks")
            badblocks_adapter "$DEV" "$SERIAL" "$LOG_DIR" 302400
            rc=$?
            ;;
    esac
    
    local ev_file="$LOG_DIR/${SERIAL}_${phase}_evidence.json"
    
    if [ ! -f "$ev_file" ] || ! jq empty "$ev_file" >/dev/null 2>&1; then
        update_phase_state "$phase" "ABORTED" 2 "ADAPTER_EVIDENCE_MISSING_OR_INVALID"
        return 2
    fi

    # 嚴格 Schema 驗證
    if ! jq -e '
        has("execution")
        and (.execution | has("status") and (.status | type == "string"))
        and (.execution | has("exit_code") and (.exit_code | type == "number"))
        and (.execution | has("reason") and (.reason | type == "string"))
    ' "$ev_file" >/dev/null 2>&1; then
        update_phase_state "$phase" "ABORTED" 2 "ADAPTER_EVIDENCE_INVALID_SCHEMA"
        return 2
    fi

    local ev_rc
    ev_rc=$(jq -r '.execution.exit_code' "$ev_file")
    local rsn
    rsn=$(jq -r '.execution.reason' "$ev_file")

    if [ "$ev_rc" != "$rc" ]; then
        update_phase_state "$phase" "ABORTED" 2 "ADAPTER_CONTRACT_VIOLATION_RC_MISMATCH"
        return 2
    fi

    case "$rc" in
        0) update_phase_state "$phase" "PASS" 0 "$rsn" ;;
        1) update_phase_state "$phase" "FAIL" 1 "$rsn" ;;
        2) update_phase_state "$phase" "ABORTED" 2 "$rsn" ;;
        130|143) update_phase_state "$phase" "INTERRUPTED" "$rc" "$rsn" ;;
        *) update_phase_state "$phase" "ABORTED" 2 "UNKNOWN_ADAPTER_EXIT" ;;
    esac

    return "$rc"
}

jq '.execution.status = "RUNNING"' "$EXEC_FILE" > "${EXEC_FILE}.tmp" && mv "${EXEC_FILE}.tmp" "$EXEC_FILE"

phases=("precheck" "baseline_snapshot" "smart_long_1" "badblocks" "smart_long_2" "final_snapshot")
execution_failed=false
final_rc=0

for p in "${phases[@]}"; do
    if [ "$execution_failed" == "true" ]; then
        update_phase_state "$p" "SKIPPED" 0 "PREVIOUS_PHASE_FAILED"
        continue
    fi

    run_phase "$p"
    rc=$?

    if [ "$rc" -ne 0 ]; then
        execution_failed=true
        final_rc=$rc
    fi
done

case $final_rc in
    0) jq '.execution.status = "COMPLETED"' "$EXEC_FILE" > "${EXEC_FILE}.tmp" && mv "${EXEC_FILE}.tmp" "$EXEC_FILE" ;;
    1) jq '.execution.status = "FAILED_EXECUTION"' "$EXEC_FILE" > "${EXEC_FILE}.tmp" && mv "${EXEC_FILE}.tmp" "$EXEC_FILE" ;;
    2) jq '.execution.status = "ABORTED"' "$EXEC_FILE" > "${EXEC_FILE}.tmp" && mv "${EXEC_FILE}.tmp" "$EXEC_FILE" ;;
    130|143) jq '.execution.status = "INTERRUPTED"' "$EXEC_FILE" > "${EXEC_FILE}.tmp" && mv "${EXEC_FILE}.tmp" "$EXEC_FILE" ;;
esac
jq '.execution.current_phase = "none"' "$EXEC_FILE" > "${EXEC_FILE}.tmp" && mv "${EXEC_FILE}.tmp" "$EXEC_FILE"

exit "$final_rc"
