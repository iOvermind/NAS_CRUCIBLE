#!/bin/bash
source "$(dirname "${BASH_SOURCE[0]}")/../lib/device_probe.sh"
# =========================================================================
# NVMe SMART Long Adapter (Device Self-test 觀測與中止邊界)
#
# 分工原則：
#   - 「啟動 / 中止」用 nvme-cli (nvme device-self-test)，因為 smartctl -t long
#     對 NVMe 需要 smartmontools 7.4+ 且部分韌體不接受。
#   - 「輪詢 / 讀結果」用 smartctl -j -l selftest，讓 Evidence 的 JSON 結構
#     與 SATA/SAS 路徑一致 (nvme-cli 的 JSON key 各版本差異過大，不可依賴)。
#
# nvme device-self-test -s 的語意 (NVMe spec / nvme-cli):
#   0x1 = short, 0x2 = extended, 0xf = abort。沒有 --action 這個選項。
# =========================================================================

NVME_STC_EXTENDED=2
NVME_STC_ABORT=0xf

# --- 獨立模組: NVMe Self-Test 狀態解析 (輸入為 smartctl -j -l selftest) ---
_parse_nvme_selftest_state() {
    local json="$1" current_op current_pct latest_val

    # smartctl 對 NVMe 的 self-test log 輸出在 .nvme_self_test_log 之下。
    # current_self_test_operation.value: 0 = 無測試進行中，1/2 = short/extended 進行中。
    current_op=$(jq -r '.nvme_self_test_log.current_self_test_operation.value // empty' <<<"$json" 2>/dev/null)
    current_pct=$(jq -r '.nvme_self_test_log.current_self_test_completion_percent // empty' <<<"$json" 2>/dev/null)

    if [ -z "$current_op" ]; then
        # 連 current_self_test_operation 都讀不到 = 韌體不支援或 JSON 結構非預期。
        # Fail-Closed：回報 UNKNOWN，由呼叫端終止，絕不假設「已完成」。
        echo "UNKNOWN"; return
    fi

    if [ "$current_op" != "0" ]; then
        echo "RUNNING"; return
    fi

    # current_op == 0：沒有測試在跑。確認 log 內確實有一筆結果才算 COMPLETE。
    # self_test_result.value 0x0=無錯誤, 0x1~0x8=各種失敗, 0xf=被中止而未完成。
    latest_val=$(jq -r '.nvme_self_test_log.table[0].self_test_result.value // empty' <<<"$json" 2>/dev/null)
    if [ -n "$latest_val" ]; then
        echo "COMPLETE"
    elif [ -n "$current_pct" ] && [ "$current_pct" != "0" ]; then
        # 進度非 0 但 op 已歸零：視為仍在收尾，續等。
        echo "RUNNING"
    else
        echo "UNKNOWN"
    fi
}

nvme_smart_long_adapter() {
    local dev=$1 serial=$2 protocol=$3 log_dir=$4 timeout_sec=${5:-86400} phase=${6:-smart}
    # 同 smartctl_long_adapter：Evidence 檔名必須吻合 runner 的 phase 契約，
    # 否則 validate_evidence 會判 ADAPTER_CONTRACT_VIOLATION。
    local start_log="$log_dir/${serial}_${phase}_start.log"
    local result_log="$log_dir/${serial}_${phase}_result.log"
    local ev_file="$log_dir/${serial}_${phase}_evidence.json"

    local final_rc=2 reason="UNCLASSIFIED_FAILURE" observation="UNKNOWN"
    local abort_signal="" abort_req="false" abort_rc="null" timeout_triggered="false"
    local exec_rc=0 poll_state="PENDING" elapsed=0 poll_interval=${SMART_POLL_INTERVAL:-300}

    trap 'abort_signal=130; abort_req="true"; nvme device-self-test -s '"$NVME_STC_ABORT"' "/dev/'"$dev"'" >/dev/null 2>&1; abort_rc=$?' INT
    trap 'abort_signal=143; abort_req="true"; nvme device-self-test -s '"$NVME_STC_ABORT"' "/dev/'"$dev"'" >/dev/null 2>&1; abort_rc=$?' TERM

    # 啟動 NVMe Extended Device Self-test
    nvme device-self-test -s "$NVME_STC_EXTENDED" "/dev/$dev" > "$start_log" 2>&1
    exec_rc=$?

    if [ "$exec_rc" -eq 0 ]; then
        while true; do
            [ -n "$abort_signal" ] && { poll_state="INTERRUPTED"; break; }
            if ! is_device_accessible "$dev"; then exec_rc=999; poll_state="ERROR"; break; fi
            if [ "$elapsed" -ge "$timeout_sec" ]; then
                timeout_triggered="true"; abort_req="true"; poll_state="TIMEOUT"
                nvme device-self-test -s "$NVME_STC_ABORT" "/dev/$dev" >/dev/null 2>&1; abort_rc=$?
                break
            fi

            local poll_out poll_rc
            poll_out=$(smartctl -j -l selftest "/dev/$dev" 2>/dev/null)
            poll_rc=$?
            # smartctl 的離開碼是 bitmask；只有 bit 0~2 (指令/通訊失敗) 代表我們讀不到資料。
            # bit 3+ 只是「碟片自己回報了健康旗標」，那是 verdict_engine 的職權，不是輪詢錯誤。
            if [ $((poll_rc & 7)) -ne 0 ]; then exec_rc=$poll_rc; poll_state="ERROR"; break; fi

            poll_state=$(_parse_nvme_selftest_state "$poll_out")

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

    # 擷取最終 self-test 結果
    if is_device_accessible "$dev" && [ -z "$abort_signal" ] && [ "$timeout_triggered" != "true" ] && [ "$exec_rc" -eq 0 ]; then
        smartctl -j -l selftest "/dev/$dev" > "$result_log" 2>&1
        observation=$(jq -r '.nvme_self_test_log.table[0].self_test_result.string // "NO_RESULT_FOUND"' "$result_log" 2>/dev/null)
        [ -n "$observation" ] || observation="NO_RESULT_FOUND"
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
         adapter: {name: "nvme_smart_long", version: "1.0"},
         execution: {status: $stat, exit_code: ($rc | tonumber), reason: $rsn},
         abort: {requested: $abt_req, command_exit_code: $abt_rc},
         observation: {self_test_result: $obs},
         poll: {state: $p_state, elapsed_seconds: $e_sec, poll_interval_seconds: $p_int}
       }' > "$ev_file" 2>/dev/null; then
        echo "❌ [nvme_smart_long_adapter] Evidence write failed: $ev_file" >&2
        return 2
    fi
    return "$final_rc"
}
