#!/bin/bash
# =========================================================================
# TrueNAS Storage Destructive Burn-in Script (V6 - M2A-2 Freeze)
# 模組: 多程序行控中心 (PGID 精準獵殺 & 嚴格狀態收尾)
# =========================================================================

TEST_SCENARIO=${1:-"ONE_DEVICE_LOST"}

echo "=========================================="
echo " 🏭 Phase 2A-2: Process Controller (Scenario: $TEST_SCENARIO)"
echo "=========================================="

# 開啟 job control，確保子程序擁有獨立的 Process Group
set -m

declare -A ACTIVE_PIDS
declare -A ACTIVE_PGIDS
GLOBAL_ABORT=false
CONTROLLER_RC=0

# ==========================================
# 子系統：強化版 Runner (嚴格對齊 M2A-1 Contract)
# ==========================================
run_simulated_workload() {
    local dev=$1
    local scenario=$2
    local fail_phase=$3
    local exec_file="./exec_record_${dev}.json"

    # M2A-1 完整 Phase 定義
    local phases=("precheck" "baseline_snapshot" "smart_long_1" "badblocks" "smart_long_2" "final_snapshot")

    # 1. 真實的 Signal Handling 與完美收尾語義
    trap 'echo "   🛑 [Runner $dev] 收到 SIGINT！"; handle_interrupt 130' INT
    trap 'echo "   🛑 [Runner $dev] 收到 SIGTERM！"; handle_interrupt 143' TERM

    handle_interrupt() {
        local sig_rc=$1
        local reason="OPERATOR_SIGINT"
        [ "$sig_rc" -eq 143 ] && reason="GLOBAL_ABORT_INFRASTRUCTURE_FAILURE"

        # 找出當下正在 RUNNING 的 phase
        local curr_phase
        curr_phase=$(jq -r '.execution.current_phase' "$exec_file")

        # 把當前 phase 標記為 INTERRUPTED
        if [ "$curr_phase" != "none" ] && [ "$curr_phase" != "null" ]; then
            update_phase_state "$curr_phase" "INTERRUPTED" "$sig_rc" "$reason"
        fi

        # 把後面沒跑到的 PENDING phase 全部改為 SKIPPED
        for p in "${phases[@]}"; do
            local st
            st=$(jq -r --arg p "$p" '.execution.phases[$p].status // "UNKNOWN"' "$exec_file")
            if [ "$st" == "PENDING" ]; then
                update_phase_state "$p" "SKIPPED" 0 "CASCADED_FROM_GLOBAL_ABORT"
            fi
        done

        jq '.execution.status = "INTERRUPTED" | .execution.current_phase = "none"' "$exec_file" > "${exec_file}.tmp" && mv "${exec_file}.tmp" "$exec_file"
        exit "$sig_rc"
    }

    # 2. 初始化 Contract (補齊 M2A-1 所有 Phase)
    cat <<EOF > "$exec_file"
{
  "serial": "$dev-SN",
  "execution": {
    "profile": "HDD_FULL_BURNIN",
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
}
EOF

    # 3. 狀態轉換守衛
    update_phase_state() {
        local phase=$1
        local new_st=$2
        local exit_code=${3:-0}
        local reason=${4:-""}

        local curr_st
        curr_st=$(jq -r --arg p "$phase" '.execution.phases[$p].status // "PHASE_NOT_FOUND"' "$exec_file")

        if [ "$curr_st" == "PHASE_NOT_FOUND" ]; then
            echo "❌ [STATE_VIOLATION] Runner $dev 試圖更新不存在的 Phase: $phase"
            exit 2
        fi

        local valid_transition=false
        # 允許 PENDING -> RUNNING 或 PENDING -> SKIPPED
        if [ "$curr_st" == "PENDING" ] && [[ "$new_st" =~ ^(RUNNING|SKIPPED)$ ]]; then
            valid_transition=true
        # 允許 RUNNING -> 結束狀態
        elif [ "$curr_st" == "RUNNING" ] && [[ "$new_st" =~ ^(PASS|FAIL|ABORTED|INTERRUPTED)$ ]]; then
            valid_transition=true
        fi

        if [ "$valid_transition" != "true" ]; then
            echo "❌ [STATE_VIOLATION] 非法轉換！$phase 無法從 $curr_st 轉移至 $new_st"
            exit 2
        fi

        if [ "$new_st" == "RUNNING" ]; then
            jq --arg p "$phase" --arg st "$new_st" \
               '.execution.current_phase = $p | .execution.phases[$p].status = $st' \
               "$exec_file" > "${exec_file}.tmp" && mv "${exec_file}.tmp" "$exec_file"
        else
            jq --arg p "$phase" --arg st "$new_st" --argjson ec "$exit_code" --arg rsn "$reason" \
               '.execution.phases[$p] = {status: $st, exit_code: $ec, reason: $rsn}' \
               "$exec_file" > "${exec_file}.tmp" && mv "${exec_file}.tmp" "$exec_file"
        fi
    }

    # 4. 模擬執行器
    simulate_actor() {
        local phase=$1
        update_phase_state "$phase" "RUNNING"
        sleep 2
        
        if [ "$fail_phase" == "$phase" ]; then
            if [ "$scenario" == "DEVICE_LOST" ]; then
                echo "   💥 [FATAL - $dev] 裝置突然消失 (I/O Error)！"
                update_phase_state "$phase" "ABORTED" 2 "DEVICE_DISAPPEARED"
                return 2
            elif [ "$scenario" == "FAIL_LOCAL" ]; then
                echo "   ❌ [ERROR - $dev] 發現壞軌 (badblocks != 0)！"
                update_phase_state "$phase" "FAIL" 1 "MEDIA_ERROR_FOUND"
                return 1
            fi
        fi
        
        update_phase_state "$phase" "PASS" 0 "COMPLETED_SUCCESSFULLY"
        return 0
    }

    jq '.execution.status = "RUNNING"' "$exec_file" > "${exec_file}.tmp" && mv "${exec_file}.tmp" "$exec_file"
    
    local execution_failed=false
    local final_rc=0

    for p in "${phases[@]}"; do
        if [ "$execution_failed" == "true" ]; then
            update_phase_state "$p" "SKIPPED" 0 "PREVIOUS_PHASE_FAILED"
            continue
        fi

        simulate_actor "$p"
        local rc=$?

        if [ $rc -ne 0 ]; then
            execution_failed=true
            final_rc=$rc
        fi
    done

    case $final_rc in
        0) jq '.execution.status = "COMPLETED"' "$exec_file" > "${exec_file}.tmp" && mv "${exec_file}.tmp" "$exec_file" ;;
        1) jq '.execution.status = "FAILED_EXECUTION"' "$exec_file" > "${exec_file}.tmp" && mv "${exec_file}.tmp" "$exec_file" ;;
        2) jq '.execution.status = "ABORTED"' "$exec_file" > "${exec_file}.tmp" && mv "${exec_file}.tmp" "$exec_file" ;;
    esac
    jq '.execution.current_phase = "none"' "$exec_file" > "${exec_file}.tmp" && mv "${exec_file}.tmp" "$exec_file"

    exit $final_rc
}

# ==========================================
# 行控中心：Controller & Global Abort 邏輯
# ==========================================
trap 'echo -e "\n🚨 [Controller] 收到操作員 SIGINT，啟動全域中止..."; trigger_global_abort 130' INT
trap 'echo -e "\n🚨 [Controller] 收到系統 SIGTERM，啟動全域中止..."; trigger_global_abort 143' TERM

trigger_global_abort() {
    local rc=$1
    if [ "$GLOBAL_ABORT" != "true" ]; then
        GLOBAL_ABORT=true
        CONTROLLER_RC=$rc
        echo "   -> 廣播 SIGTERM 終止信號給所有執行中的 Runners Process Group..."
        for pid in "${!ACTIVE_PIDS[@]}"; do
            local pgid="${ACTIVE_PGIDS[$pid]}"
            if [ -n "$pgid" ]; then
                kill -TERM -- "-$pgid" 2>/dev/null
            else
                kill -TERM "$pid" 2>/dev/null
            fi
        done
    fi
}

DRIVES=("sda" "sdb" "sdc" "sdd" "sde" "sdf")
for dev in "${DRIVES[@]}"; do
    cfg_scenario="PASS"
    cfg_fail="none"
    
    if [ "$TEST_SCENARIO" == "ONE_LOCAL_FAIL" ] && [ "$dev" == "sdc" ]; then
        cfg_scenario="FAIL_LOCAL"
        cfg_fail="badblocks"
    elif [ "$TEST_SCENARIO" == "ONE_DEVICE_LOST" ] && [ "$dev" == "sdc" ]; then
        cfg_scenario="DEVICE_LOST"
        cfg_fail="badblocks"
    fi

    # 放進背景執行
    run_simulated_workload "$dev" "$cfg_scenario" "$cfg_fail" &
    pid=$!
    
    # 確保取得 PGID
    pgid=$(ps -o pgid= -p "$pid" | grep -Eo '[0-9]+')
    
    ACTIVE_PIDS["$pid"]="$dev"
    ACTIVE_PGIDS["$pid"]="$pgid"
    echo "🚀 啟動 Runner [$dev] (PID: $pid, PGID: $pgid)"
done

echo "=========================================="
echo " 📡 Controller: 進入監聽迴圈 (Waiting for exits...)"
echo "=========================================="

while [ ${#ACTIVE_PIDS[@]} -gt 0 ]; do
    wait -n 2>/dev/null
    
    for pid in "${!ACTIVE_PIDS[@]}"; do
        if ! kill -0 "$pid" 2>/dev/null; then
            dev="${ACTIVE_PIDS[$pid]}"
            wait "$pid" 2>/dev/null
            rc=$?
            unset ACTIVE_PIDS["$pid"]
            unset ACTIVE_PGIDS["$pid"]

            echo "📊 [Controller] Runner $dev 結束 (Exit Code: $rc)"

            if [ $rc -eq 1 ]; then
                echo "   -> $dev 單機任務失敗 (LOCAL FAIL)，其餘盤繼續執行。"
            elif [[ $rc -eq 2 || $rc -eq 130 || $rc -eq 143 ]]; then
                if [ "$GLOBAL_ABORT" != "true" ]; then
                    echo "🚨 [Controller] 偵測到基礎設施崩潰或中斷信號 (來自 $dev, RC=$rc)！"
                    trigger_global_abort $rc
                fi
            fi
        fi
    done
done

echo "=========================================="
if [ "$GLOBAL_ABORT" == "true" ]; then
    echo "💀 Controller: 執行已被全域中止 (ABORTED)。"
    exit $CONTROLLER_RC
else
    echo "🎉 Controller: 所有 Runner 已收尾完成。"
    exit 0
fi
