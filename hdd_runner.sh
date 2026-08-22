#!/bin/bash
# =========================================================================
# 模組: HDD Runner (獨立 Process, 嚴格狀態守衛與契約警察)
# =========================================================================

SERIAL=$1
DEV=$2
PROFILE=$3
POL_NAME=$4
POL_VER=$5

EXEC_FILE="./logs/exec_record_${SERIAL}.json"

# =========================================================
# 🧪 Mock Adapter (供整合演練使用，未來替換為真實 Adapter)
# =========================================================
mock_adapter() {
    local phase=$1
    local ev_file="./logs/${SERIAL}_${phase}_evidence.json"
    
    local inject_var="SIM_${SERIAL//-/_}_${phase}_RC"
    local inject_no_evd_var="SIM_${SERIAL//-/_}_${phase}_NO_EVD"
    local inject_bad_schema="SIM_${SERIAL//-/_}_${phase}_BAD_SCHEMA"
    
    local rc=${!inject_var:-0}
    local no_evd=${!inject_no_evd_var:-false}
    local bad_schema=${!inject_bad_schema:-false}
    
    [[ "$rc" =~ ^[0-9]+$ ]] || rc=2
    sleep 1 

    local status="COMPLETED"
    local reason="COMPLETED_SUCCESSFULLY"
    case $rc in
        1) status="FAILED"; reason="WORKLOAD_FAILED" ;;
        2) status="ABORTED"; reason="INFRASTRUCTURE_OR_UNCLASSIFIED_FAILURE" ;;
        130|143) status="INTERRUPTED"; reason="INTERRUPTED_BY_SIGNAL" ;;
    esac

    if [ "$no_evd" != "true" ]; then
        if [ "$bad_schema" == "true" ]; then
            # 產出缺少必要欄位或型別錯誤的惡意 JSON
            echo '{"execution": {"status": "PASS", "exit_code": "NOT_A_NUMBER"}}' > "$ev_file"
        else
            jq -n \
               --argjson rc "$rc" \
               --arg rsn "$reason" \
               --arg stat "$status" \
               '{
                 "adapter": {"name": "mock"},
                 "execution": {"status": $stat, "exit_code": $rc, "reason": $rsn}
               }' > "$ev_file"
        fi
    fi
    return "$rc"
}

# =========================================================
# 📦 Runner 骨架與狀態守衛
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

    if [ "$curr_st" == "PHASE_NOT_FOUND" ]; then
        echo "❌ [Runner $SERIAL] 試圖更新不存在的 Phase: $p"
        exit 2
    fi

    local valid=false
    if [ "$curr_st" == "PENDING" ] && [[ "$new_st" =~ ^(RUNNING|SKIPPED)$ ]]; then valid=true; fi
    if [ "$curr_st" == "RUNNING" ] && [[ "$new_st" =~ ^(PASS|FAIL|ABORTED|INTERRUPTED)$ ]]; then valid=true; fi

    if [ "$valid" != "true" ]; then
        echo "❌ [Runner $SERIAL] 狀態轉換異常: $p ($curr_st -> $new_st)"
        exit 2
    fi

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

run_phase() {
    local phase=$1
    update_phase_state "$phase" "RUNNING"
    
    # 呼叫 Adapter Boundary (此處為 Mock)
    mock_adapter "$phase"
    local rc=$?
    
    # ==============================================
    # 🚔 契約警察 (Runner Validation of Adapter Contract)
    # ==============================================
    local ev_file="./logs/${SERIAL}_${phase}_evidence.json"
    
    if [ ! -f "$ev_file" ]; then
        update_phase_state "$phase" "ABORTED" 2 "ADAPTER_EVIDENCE_MISSING"
        return 2
    fi

    # 嚴格 Schema 驗證 (確保必要欄位存在且型別正確)
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

    # 驗證 RC 是否一致 (防堵 Adapter 掛羊頭賣狗肉)
    if [ "$ev_rc" != "$rc" ]; then
        update_phase_state "$phase" "ABORTED" 2 "ADAPTER_CONTRACT_VIOLATION_RC_MISMATCH"
        return 2
    fi

    # 依照 RC 正規化流轉
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
