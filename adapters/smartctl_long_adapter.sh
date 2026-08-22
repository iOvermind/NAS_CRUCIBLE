#!/bin/bash
source "$(dirname "${BASH_SOURCE[0]}")/../lib/device_probe.sh"
# =========================================================================
# M2A-3B: SMART Long Adapter (Device-driven 觀測與中止邊界)
# =========================================================================

# --- 獨立模組: 基礎設施防護 ---

# --- 獨立模組: SMART Polling State Parsers ---
_parse_ata_poll_state() {
    local json="$1" remaining status_str
    remaining=$(echo "$json" | jq -r '.ata_smart_data.self_test.status.remaining_percent // empty' 2>/dev/null)
    status_str=$(echo "$json" | jq -r '.ata_smart_data.self_test.status.string // empty' 2>/dev/null)

    if [ -n "$remaining" ] && [ "$remaining" -gt 0 ]; then echo "RUNNING"
    elif [[ "$status_str" =~ "in progress" ]]; then echo "RUNNING"
    elif [ "$remaining" == "0" ] || [[ "$status_str" =~ "Completed" ]] || [[ "$status_str" =~ "without error" ]]; then echo "COMPLETE"
    else echo "UNKNOWN"; fi
}

_parse_scsi_poll_state() {
    local json="$1" scsi_status scsi_pct
    scsi_status=$(echo "$json" | jq -r '.scsi_self_test_status.self_test_execution_status // empty' 2>/dev/null)
    scsi_pct=$(echo "$json" | jq -r '.scsi_self_test_status.self_test_execution_percent // empty' 2>/dev/null)
    
    if [ -n "$scsi_pct" ] && [ "$scsi_pct" -gt 0 ]; then echo "RUNNING"
    elif [ "$scsi_pct" == "0" ]; then echo "COMPLETE"
    elif [[ "$scsi_status" =~ "in progress" ]]; then echo "RUNNING"
    elif [[ "$scsi_status" =~ "completed" ]] || [[ "$scsi_status" =~ "Completed" ]]; then echo "COMPLETE"
    else echo "UNKNOWN"; fi
}

smartctl_long_adapter() {
    local dev=$1 serial=$2 protocol=$3 log_dir=$4 timeout_sec=${5:-86400}
    local start_log="$log_dir/${serial}_smart_start.log"
    local result_log="$log_dir/${serial}_smart_result.log"
    local ev_file="$log_dir/${serial}_smart_evidence.json"
    
    local final_rc=2 reason="UNCLASSIFIED_FAILURE" observation="UNKNOWN"
    local abort_signal="" abort_req="false" abort_rc="null" timeout_triggered="false"
    local exec_rc=0 poll_state="PENDING" elapsed=0 poll_interval=${SMART_POLL_INTERVAL:-300}

    trap 'abort_signal=130; abort_req="true"; smartctl -X "/dev/$dev" >/dev/null 2>&1; abort_rc=$?' INT
    trap 'abort_signal=143; abort_req="true"; smartctl -X "/dev/$dev" >/dev/null 2>&1; abort_rc=$?' TERM

    smartctl -t long "/dev/$dev" > "$start_log" 2>&1
    exec_rc=$?

    if [ "$exec_rc" -eq 0 ]; then
        while true; do
            [ -n "$abort_signal" ] && { poll_state="INTERRUPTED"; break; }
            if ! is_device_accessible "$dev"; then exec_rc=999; poll_state="ERROR"; break; fi
            if [ "$elapsed" -ge "$timeout_sec" ]; then
                timeout_triggered="true"; abort_req="true"; poll_state="TIMEOUT"
                smartctl -X "/dev/$dev" >/dev/null 2>&1; abort_rc=$?; break
            fi

            local poll_out poll_rc
            poll_out=$(smartctl -j -c "/dev/$dev" 2>/dev/null)
            poll_rc=$?
            if [ "$poll_rc" -ne 0 ]; then exec_rc=$poll_rc; poll_state="ERROR"; break; fi

            if [ "$protocol" == "ATA" ]; then poll_state=$(_parse_ata_poll_state "$poll_out")
            elif [ "$protocol" == "SCSI" ]; then poll_state=$(_parse_scsi_poll_state "$poll_out")
            else poll_state="UNSUPPORTED"; fi

            if [ "$poll_state" == "RUNNING" ]; then
                sleep "$poll_interval"
                elapsed=$((elapsed+poll_interval))
                continue
            elif [ "$poll_state" == "COMPLETE" ]; then break
            else exec_rc=888; break; fi
        done
    else
        poll_state="ERROR"
    fi

    trap - INT TERM

    if is_device_accessible "$dev" && [ -z "$abort_signal" ] && [ "$timeout_triggered" != "true" ] && [ "$exec_rc" -eq 0 ]; then
        smartctl -j -l selftest "/dev/$dev" > "$result_log" 2>&1
        local ata_status scsi_status
        ata_status=$(jq -r '.ata_smart_data.self_test_log.standard.table[0].status.string // empty' "$result_log" 2>/dev/null)
        scsi_status=$(jq -r '.scsi_self_test_log.standard.table[0].status.string // empty' "$result_log" 2>/dev/null)
        observation="${ata_status:-${scsi_status:-"NO_RESULT_FOUND"}}"
    fi

    if [ -n "$abort_signal" ]; then final_rc=$abort_signal; reason="INTERRUPTED_BY_SIGNAL"
    elif [ "$timeout_triggered" == "true" ]; then final_rc=2; reason="WORKLOAD_TIMEOUT_OR_ENVIRONMENT_FAILURE"
    elif [ "$exec_rc" -eq 999 ]; then final_rc=2; reason="INFRASTRUCTURE_DEVICE_LOST_OR_TRANSPORT_BROKEN"
    elif [ "$exec_rc" -eq 888 ]; then final_rc=2; reason="SMART_STATUS_UNPARSEABLE"
    elif [ "$exec_rc" -ne 0 ]; then
        if ! is_device_accessible "$dev"; then final_rc=2; reason="INFRASTRUCTURE_DEVICE_LOST_OR_TRANSPORT_BROKEN"
        elif [ "$exec_rc" -eq 127 ]; then final_rc=2; reason="EXECUTOR_NOT_FOUND"
        else final_rc=1; reason="WORKLOAD_COMMAND_FAILED"; fi
    else final_rc=0; reason="COMPLETED_SUCCESSFULLY"; fi

    local ev_status="UNKNOWN"
    case $final_rc in
        0) ev_status="COMPLETED" ;; 1) ev_status="FAILED" ;;
        2) ev_status="ABORTED" ;; 130|143) ev_status="INTERRUPTED" ;;
    esac

    if ! jq -n \
       --arg dev "$dev" --arg sn "$serial" --argjson rc "$final_rc" --arg rsn "$reason" \
       --arg stat "$ev_status" --arg obs "$observation" --argjson abt_req "$abort_req" \
       --argjson abt_rc "${abort_rc:-null}" --arg p_state "$poll_state" \
       --argjson e_sec "$elapsed" --argjson p_int "$poll_interval" \
       '{
         adapter: {name: "smartctl_long", version: "1.0"},
         execution: {status: $stat, exit_code: ($rc | tonumber), reason: $rsn},
         abort: {requested: $abt_req, command_exit_code: $abt_rc},
         observation: {self_test_result: $obs},
         poll: {state: $p_state, elapsed_seconds: $e_sec, poll_interval_seconds: $p_int}
       }' > "$ev_file" 2>/dev/null; then
        echo "❌ [smartctl_long_adapter] Evidence write failed: $ev_file" >&2
        return 2
    fi
    return "$final_rc"
}
