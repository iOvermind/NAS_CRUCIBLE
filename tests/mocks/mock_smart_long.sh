#!/bin/bash
# =========================================================================
# TrueNAS Storage Destructive Burn-in Script (V6 - M2A-3B Freeze)
# 模組: SMART Long Workload Adapter (JSON-first 狀態機與分離式 Parser)
# =========================================================================

mkdir -p "./logs"
export SIM_ENV="true"

# ---------------------------------------------------------
# 🛡️ 基礎設施與證據寫入注入
# ---------------------------------------------------------
is_device_accessible() {
    local dev=$1
    [ "$SIM_DEVICE_LOST" == "true" ] && return 1
    [ -b "/dev/$dev" ] || return 1
    [ -e "/sys/class/block/$dev/device" ] || return 1
    [ "$SIM_TRANSPORT_BROKEN" == "true" ] && return 1
    return 0 
}

write_evidence() {
    local out_file=$1
    local json=$2
    if [ "$SIM_EVIDENCE_WRITE_FAIL" == "true" ]; then
        return 1
    fi
    printf '%s\n' "$json" > "$out_file" 2>/dev/null
}

# ---------------------------------------------------------
# 🔍 獨立模組: SMART Polling State Parsers (ATA / SCSI 分離)
# ---------------------------------------------------------
parse_ata_poll_state() {
    local json="$1"
    
    local remaining
    remaining=$(echo "$json" | jq -r '.ata_smart_data.self_test.status.remaining_percent // empty' 2>/dev/null)
    local status_str
    status_str=$(echo "$json" | jq -r '.ata_smart_data.self_test.status.string // empty' 2>/dev/null)

    if [ -n "$remaining" ] && [ "$remaining" -gt 0 ]; then
        echo "RUNNING"
    elif [[ "$status_str" =~ "in progress" ]]; then
        echo "RUNNING"
    elif [ "$remaining" == "0" ] || [[ "$status_str" =~ "Completed" ]] || [[ "$status_str" =~ "without error" ]]; then
        echo "COMPLETE"
    else
        echo "UNKNOWN"
    fi
}

parse_scsi_poll_state() {
    local json="$1"
    
    # 支援 smartmontools 8.0+ 的 SCSI schema
    local scsi_status
    scsi_status=$(echo "$json" | jq -r '.scsi_self_test_status.self_test_execution_status // empty' 2>/dev/null)
    local scsi_pct
    scsi_pct=$(echo "$json" | jq -r '.scsi_self_test_status.self_test_execution_percent // empty' 2>/dev/null)
    
    if [ -n "$scsi_pct" ] && [ "$scsi_pct" -gt 0 ]; then
        echo "RUNNING"
    elif [ "$scsi_pct" == "0" ]; then
        echo "COMPLETE"
    # Fallback 給舊版缺少 pct 欄位的狀態
    elif [[ "$scsi_status" =~ "in progress" ]]; then
        echo "RUNNING"
    elif [[ "$scsi_status" =~ "completed" ]] || [[ "$scsi_status" =~ "Completed" ]]; then
        echo "COMPLETE"
    else
        echo "UNKNOWN"
    fi
}

parse_smart_poll() {
    local json="$1"
    local proto="$2"
    
    if [ "$proto" == "ATA" ]; then
        parse_ata_poll_state "$json"
    elif [ "$proto" == "SCSI" ]; then
        parse_scsi_poll_state "$json"
    else
        echo "UNSUPPORTED"
    fi
}

# ---------------------------------------------------------
# 🔌 Executors (Mock & Real)
# ---------------------------------------------------------
real_smartctl_executor() {
    smartctl "$@"
}
export -f real_smartctl_executor

mock_smartctl_executor() {
    local action=$1
    local dev=""
    local state_file=""

    for arg in "$@"; do
        if [[ "$arg" == /dev/* ]]; then
            dev=${arg##*/}
            state_file="./logs/mock_smart_state_${dev}"
            break
        fi
    done
    [ -z "$state_file" ] && state_file="./logs/mock_smart_state_unknown"

    if [ "$action" == "-i" ]; then
        return 0
    elif [ "$action" == "-t" ]; then
        echo "10" > "$state_file" 
        return 0
    elif [ "$action" == "-X" ]; then
        echo "0" > "$state_file"
        return 0
    elif [ "$action" == "-j" ] && [ "$2" == "-c" ]; then
        local loops
        loops=$(cat "$state_file" 2>/dev/null || echo "0")
        
        if [ "$SIM_HANG" == "true" ] || [ "$loops" -gt 0 ]; then
            echo '{"ata_smart_data": {"self_test": {"status": {"remaining_percent": 10, "string": "Self-test routine in progress"}}}}'
            [ "$SIM_HANG" != "true" ] && echo $((loops - 1)) > "$state_file"
        elif [ "$SIM_UNPARSEABLE" == "true" ]; then
            echo '{"ata_smart_data": {"weird_format": true}}'
        else
            echo '{"ata_smart_data": {"self_test": {"status": {"remaining_percent": 0, "string": "Completed without error"}}}}'
        fi
        return 0
    elif [ "$action" == "-j" ] && [ "$2" == "-l" ]; then
        if [ "$SIM_SCENARIO" == "FAIL_MEDIA" ]; then
            echo '{"ata_smart_data": {"self_test_log": {"standard": {"table": [{"status": {"string": "Completed: read failure"}}]}}}}'
        elif [ "$SIM_SCENARIO" == "ABORTED_BY_DRIVE" ]; then
            echo '{"ata_smart_data": {"self_test_log": {"standard": {"table": [{"status": {"string": "Aborted by host"}}]}}}}'
        else
            echo '{"ata_smart_data": {"self_test_log": {"standard": {"table": [{"status": {"string": "Completed without error"}}]}}}}'
        fi
        return 0
    fi
    
    return 1
}
export -f mock_smartctl_executor

# =========================================================
# 📦 核心邊界: SMART Long Adapter
# =========================================================
smartctl_long_adapter() {
    local dev=$1
    local serial=$2
    local protocol=$3  # ATA 或 SCSI
    local log_dir=$4
    local timeout_sec=${5:-86400}
    local executor=${6:-"real_smartctl_executor"}

    local start_log="$log_dir/${serial}_smart_start.log"
    local result_log="$log_dir/${serial}_smart_result.log"
    local ev_file="$log_dir/${serial}_smart_evidence.json"
    
    local final_rc=2
    local reason="UNCLASSIFIED_FAILURE"
    local observation="UNKNOWN"
    
    local abort_signal=""
    local abort_req="false"
    local abort_rc="null"
    local timeout_triggered="false"
    local exec_rc=0
    local poll_state="PENDING"
    local elapsed=0
    local poll_interval=1 # 實機為 300

    if ! declare -F "$executor" >/dev/null 2>&1 && ! command -v "$executor" >/dev/null 2>&1; then
        reason="EXECUTOR_NOT_FOUND"
        poll_state="ERROR"
    else
        trap '
            abort_signal=130; abort_req="true"
            echo "   [Adapter] 收到 SIGINT，向硬碟發送 Abort 指令 (-X)..."
            "$executor" -X "/dev/$dev" >/dev/null 2>&1
            abort_rc=$?
        ' INT
        trap '
            abort_signal=143; abort_req="true"
            echo "   [Adapter] 收到 SIGTERM，向硬碟發送 Abort 指令 (-X)..."
            "$executor" -X "/dev/$dev" >/dev/null 2>&1
            abort_rc=$?
        ' TERM

        "$executor" -t long "/dev/$dev" > "$start_log" 2>&1
        exec_rc=$?

        if [ "$exec_rc" -eq 0 ]; then
            while true; do
                if [ -n "$abort_signal" ]; then
                    poll_state="INTERRUPTED"
                    break
                fi

                if ! is_device_accessible "$dev"; then
                    exec_rc=999
                    poll_state="ERROR"
                    break
                fi
                
                if [ "$elapsed" -ge "$timeout_sec" ]; then
                    timeout_triggered="true"
                    abort_req="true"
                    poll_state="TIMEOUT"
                    "$executor" -X "/dev/$dev" >/dev/null 2>&1
                    abort_rc=$?
                    break
                fi

                local poll_out
                poll_out=$("$executor" -j -c "/dev/$dev" 2>/dev/null)
                local poll_rc=$?

                if [ "$poll_rc" -ne 0 ]; then
                    exec_rc=$poll_rc
                    poll_state="ERROR"
                    break
                fi

                # 呼叫 Parser 解析狀態
                poll_state=$(parse_smart_poll "$poll_out" "$protocol")

                if [ "$poll_state" == "RUNNING" ]; then
                    sleep "$poll_interval"
                    elapsed=$((elapsed+poll_interval))
                    continue
                elif [ "$poll_state" == "COMPLETE" ]; then
                    break
                else
                    exec_rc=888 # 無法解析
                    break
                fi
            done
        else
            poll_state="ERROR"
        fi

        trap - INT TERM

        if is_device_accessible "$dev" && [ -z "$abort_signal" ] && [ "$timeout_triggered" != "true" ] && [ "$exec_rc" -eq 0 ]; then
            "$executor" -j -l selftest "/dev/$dev" > "$result_log" 2>&1
            local ata_status scsi_status
            ata_status=$(jq -r '.ata_smart_data.self_test_log.standard.table[0].status.string // empty' "$result_log" 2>/dev/null)
            scsi_status=$(jq -r '.scsi_self_test_log.standard.table[0].status.string // empty' "$result_log" 2>/dev/null)
            observation="${ata_status:-${scsi_status:-"NO_RESULT_FOUND"}}"
        fi

        if [ -n "$abort_signal" ]; then
            final_rc=$abort_signal
            reason="INTERRUPTED_BY_SIGNAL"
        elif [ "$timeout_triggered" == "true" ]; then
            final_rc=2
            reason="WORKLOAD_TIMEOUT_OR_ENVIRONMENT_FAILURE"
        elif [ "$exec_rc" -eq 999 ]; then
            final_rc=2
            reason="INFRASTRUCTURE_DEVICE_LOST_OR_TRANSPORT_BROKEN"
        elif [ "$exec_rc" -eq 888 ]; then
            final_rc=2
            reason="SMART_STATUS_UNPARSEABLE"
        elif [ "$exec_rc" -ne 0 ]; then
            if ! is_device_accessible "$dev"; then
                final_rc=2
                reason="INFRASTRUCTURE_DEVICE_LOST_OR_TRANSPORT_BROKEN"
            elif [ "$exec_rc" -eq 127 ]; then
                final_rc=2
                reason="EXECUTOR_NOT_FOUND"
            else
                final_rc=1
                reason="WORKLOAD_COMMAND_FAILED"
            fi
        else
            final_rc=0
            reason="COMPLETED_SUCCESSFULLY"
        fi
    fi

    local ev_status="UNKNOWN"
    case $final_rc in
        0) ev_status="COMPLETED" ;;
        1) ev_status="FAILED" ;;
        2) ev_status="ABORTED" ;;
        130|143) ev_status="INTERRUPTED" ;;
    esac

    local json
    json=$(jq -n \
       --arg dev "$dev" \
       --arg sn "$serial" \
       --argjson rc "$final_rc" \
       --arg rsn "$reason" \
       --arg stat "$ev_status" \
       --arg obs "$observation" \
       --argjson abt_req "$abort_req" \
       --argjson abt_rc "${abort_rc:-null}" \
       --arg p_state "$poll_state" \
       --argjson e_sec "$elapsed" \
       --argjson p_int "$poll_interval" \
       '{
         "adapter": {"name": "smartctl_long", "version": "1.0"},
         "device": {"handle": $dev, "serial": $sn},
         "execution": {"status": $stat, "exit_code": $rc, "reason": $rsn},
         "abort": {"requested": $abt_req, "command_exit_code": $abt_rc},
         "observation": {"self_test_result": $obs},
         "poll": {"state": $p_state, "elapsed_seconds": $e_sec, "poll_interval_seconds": $p_int}
       }')

    if ! write_evidence "$ev_file" "$json"; then
        echo "❌ [Adapter] 嚴重錯誤：Evidence JSON 寫入失敗 ($ev_file)"
        return 2
    fi

    return $final_rc
}

# =========================================================
# 🧪 測試治具: Adapter Test Harness
# =========================================================
run_test_case() {
    local name=$1
    local expected_rc=$2
    export SIM_SCENARIO=$3
    export SIM_DEVICE_LOST=${4:-"false"}
    export SIM_TRANSPORT_BROKEN=${5:-"false"}
    export SIM_EVIDENCE_WRITE_FAIL=${6:-"false"}
    export SIM_UNPARSEABLE=${7:-"false"}
    local timeout=${8:-86400}
    local sig=${9:-""}
    local force_executor=${10:-"mock_smartctl_executor"}

    echo "---------------------------------------------------"
    echo "▶️  測試案例: $name"
    
    smartctl_long_adapter "sdx" "SN-TEST" "ATA" "./logs" "$timeout" "$force_executor" &
    local adapter_pid=$!

    if [ -n "$sig" ]; then
        sleep 0.5
        kill -$sig "$adapter_pid"
    fi

    wait "$adapter_pid"
    local actual_rc=$?

    if [ $actual_rc -eq $expected_rc ]; then
        echo "✅ RC 通過 ($actual_rc)"
        if [ "$SIM_EVIDENCE_WRITE_FAIL" != "true" ]; then
            jq -C . "./logs/SN-TEST_smart_evidence.json" | sed 's/^/   /'
        fi
    else
        echo "❌ RC 失敗 (預期 $expected_rc, 實際 $actual_rc)"
    fi
}

echo "開始執行 SMART Adapter Contract 測試..."

run_test_case "順利跑完 (健康盤)" 0 "PASS"
run_test_case "順利跑完 (媒體讀取錯誤)" 0 "FAIL_MEDIA"
run_test_case "測試完成但狀態無法解析 (Fail-closed)" 2 "PASS" "false" "false" "false" "true"
run_test_case "中途控制器掉盤 (DEVICE_LOST)" 2 "PASS" "true"
run_test_case "指令檔不存在 (127)" 2 "PASS" "false" "false" "false" "false" 86400 "" "nonexistent_smartctl"
run_test_case "證據 JSON 寫入失敗" 2 "PASS" "false" "false" "true"

export SIM_HANG="true"
run_test_case "Workload 進度卡死 (Timeout 3s)" 2 "PASS" "false" "false" "false" "false" 3
run_test_case "收到 SIGTERM (向硬碟發出 -X)" 143 "PASS" "false" "false" "false" "false" 86400 "TERM"
export SIM_HANG="false"

echo "---------------------------------------------------"
echo "🏁 測試矩陣執行完畢。"
