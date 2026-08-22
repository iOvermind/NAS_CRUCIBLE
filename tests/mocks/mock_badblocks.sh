#!/bin/bash
# =========================================================================
# TrueNAS Storage Destructive Burn-in Script (V6 - M2A-3A Freeze)
# 模組: Workload Adapter Boundary (嚴格副作用與生命週期隔離)
# =========================================================================

mkdir -p "./logs"
export SIM_ENV="true"

# ---------------------------------------------------------
# 🛡️ 基礎設施探測 (三層深度驗證)
# ---------------------------------------------------------
is_device_accessible() {
    local dev=$1
    
    [ "$SIM_DEVICE_LOST" == "true" ] && return 1
    
    # 1. 區塊裝置是否存在
    [ -b "/dev/$dev" ] || return 1
    
    # 2. Sysfs 節點是否存在 (防止 zombie device node)
    [ -e "/sys/class/block/$dev/device" ] || return 1
    
    # 3. 通訊與傳輸層健康度
    [ "$SIM_TRANSPORT_BROKEN" == "true" ] && return 1
    if [ "$SIM_ENV" != "true" ]; then
        smartctl -i "/dev/$dev" >/dev/null 2>&1 || return 1
    fi
    
    return 0 
}

# ---------------------------------------------------------
# 🔌 Executors (依賴注入與介面化)
# ---------------------------------------------------------
real_badblocks_executor() {
    local dev=$1
    local log=$2
    badblocks -wsv -b 4096 "/dev/$dev" > "$log" 2>&1
}
export -f real_badblocks_executor

mock_badblocks_executor() {
    local dev=$1
    local log=$2
    echo "[$SIM_SCENARIO] 執行模擬 Workload 於 $dev" > "$log"
    
    case "$SIM_SCENARIO" in
        "PASS") sleep 1; exit 0 ;;
        "FAIL_LOCAL") sleep 1; exit 1 ;;
        "DEVICE_LOST") sleep 1; exit 1 ;; 
        "ARG_ERROR") sleep 1; exit 255 ;;
        "HANG") sleep 10; exit 0 ;;
        "CHILD_DESCENDANT")
            # 建立多層子程序，測試 setsid 是否能將 PGID 一網打盡
            bash -c 'sleep 30' &
            sleep 30
            exit 0
            ;;
    esac
}
export -f mock_badblocks_executor

# =========================================================
# 📦 核心邊界: Badblocks Adapter (純契約回傳)
# =========================================================
badblocks_adapter() {
    local dev=$1
    local serial=$2
    local log_dir=$3
    local timeout_sec=${4:-302400}
    local executor=${5:-"real_badblocks_executor"}

    local log_file="$log_dir/${serial}_badblocks.log"
    local ev_file="$log_dir/${serial}_badblocks_evidence.json"
    
    local final_rc=2
    local reason="UNCLASSIFIED_FAILURE"
    local child_pid=0
    local child_pgid=0

    # 1. 嚴格檢驗 Executor 合法性
    if ! declare -F "$executor" >/dev/null 2>&1 && ! command -v "$executor" >/dev/null 2>&1; then
        reason="EXECUTOR_NOT_FOUND"
    else
        local abort_signal=""
        local timeout_triggered="false"
        local raw_rc=0

        # 綁定 Signal Trap，精準轉發給 PGID
        trap 'abort_signal=130; [ -n "$child_pgid" ] && kill -TERM -- "-$child_pgid" 2>/dev/null' INT
        trap 'abort_signal=143; [ -n "$child_pgid" ] && kill -TERM -- "-$child_pgid" 2>/dev/null' TERM

        # 2. 建立獨立 Session 與 Process Group (籠中籠)
        setsid bash -c '"$@"' _ "$executor" "$dev" "$log_file" &
        child_pid=$!
        child_pgid=$child_pid # setsid 讓子程序成為 Session Leader (PID = PGID)

        # 3. 獨立 Watchdog 迴圈 (剝離 Bash Wait Signal 競爭)
        local elapsed=0
        while true; do
            if [ -n "$abort_signal" ]; then
                wait "$child_pid" 2>/dev/null
                break
            fi
            
            if ! kill -0 "$child_pid" 2>/dev/null; then
                wait "$child_pid" 2>/dev/null
                raw_rc=$?
                break
            fi

            if [ "$elapsed" -ge "$timeout_sec" ]; then
                timeout_triggered="true"
                kill -TERM -- "-$child_pgid" 2>/dev/null
                wait "$child_pid" 2>/dev/null
                raw_rc=$?
                break
            fi

            sleep 1
            elapsed=$((elapsed+1))
        done

        trap - INT TERM

        # 4. 死因正規化與鑑識 (The Blame Game)
        if [ -n "$abort_signal" ]; then
            final_rc=$abort_signal
            reason="INTERRUPTED_BY_SIGNAL"
        elif [ "$timeout_triggered" == "true" ]; then
            final_rc=2
            reason="WORKLOAD_TIMEOUT_OR_ENVIRONMENT_FAILURE"
        elif [ "$raw_rc" -eq 0 ]; then
            final_rc=0
            reason="WORKLOAD_COMPLETED"
        elif [ "$raw_rc" -eq 1 ]; then
            if ! is_device_accessible "$dev"; then
                final_rc=2
                reason="INFRASTRUCTURE_DEVICE_LOST_OR_TRANSPORT_BROKEN"
            else
                final_rc=1
                reason="WORKLOAD_FAILED"
            fi
        else
            final_rc=2
            reason="INFRASTRUCTURE_OR_UNCLASSIFIED_FAILURE"
        fi
    fi

    # 5. 狀態對齊與 Evidence 產出
    local ev_status="UNKNOWN"
    case $final_rc in
        0) ev_status="COMPLETED" ;;
        1) ev_status="FAILED" ;;
        2) ev_status="ABORTED" ;;
        130|143) ev_status="INTERRUPTED" ;;
    esac

    # 6. 證據寫入驗證 (寫入失敗視同 Infra 崩潰)
    if ! jq -n \
       --arg dev "$dev" \
       --arg sn "$serial" \
       --argjson rc "$final_rc" \
       --arg rsn "$reason" \
       --argjson pid "${child_pid:-0}" \
       --argjson pgid "${child_pgid:-0}" \
       --arg stat "$ev_status" \
       '{
         "adapter": {"name": "badblocks", "version": "1.0"},
         "device": {"handle": $dev, "serial": $sn},
         "process": {"pid": $pid, "pgid": $pgid},
         "execution": {"status": $stat, "exit_code": $rc, "reason": $rsn}
       }' > "$ev_file" 2>/dev/null; then
        
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
    local timeout=${6:-302400}
    local sig=${7:-""}
    local force_executor=${8:-"mock_badblocks_executor"}

    echo "---------------------------------------------------"
    echo "▶️  測試案例: $name"
    
    badblocks_adapter "sdx" "SN-TEST" "./logs" "$timeout" "$force_executor" &
    local adapter_pid=$!

    if [ -n "$sig" ]; then
        sleep 0.5
        kill -$sig "$adapter_pid"
    fi

    wait "$adapter_pid"
    local actual_rc=$?

    if [ $actual_rc -eq $expected_rc ]; then
        echo "✅ RC 通過 ($actual_rc)"
        # 僅在未發生物理讀寫錯誤時驗證 JSON
        if [ "$SIM_SCENARIO" != "EVIDENCE_WRITE_FAIL" ]; then
            jq -C . "./logs/SN-TEST_badblocks_evidence.json" | sed 's/^/   /'
        fi
    else
        echo "❌ RC 失敗 (預期 $expected_rc, 實際 $actual_rc)"
    fi
}

echo "開始執行 Adapter Contract 測試..."

# 基礎路徑
run_test_case "順利跑完 (PASS)" 0 "PASS"
run_test_case "明確磁碟壞軌 (FAIL_LOCAL)" 1 "FAIL_LOCAL"
run_test_case "中途控制器掉盤 (DEVICE_LOST)" 2 "DEVICE_LOST" "true"

# 邊界路徑 (Infra)
run_test_case "指令檔/函數不存在" 2 "PASS" "false" "false" 300 "" "nonexistent_badblocks_xyz"
run_test_case "/dev 存在但 Transport 異常 (SMART Timeout)" 2 "DEVICE_LOST" "false" "true"
run_test_case "未知參數或環境錯誤" 2 "ARG_ERROR"

# Signal / Timeout 隔離控制
run_test_case "Workload 卡死 (Timeout 2s)" 2 "HANG" "false" "false" 2
run_test_case "Controller 全域中止 (SIGTERM 擊斃深層子程序)" 143 "CHILD_DESCENDANT" "false" "false" 300 "TERM"

# Evidence 鐵律
chmod -w "./logs"
run_test_case "證據 JSON 寫入失敗 (唯讀 FS)" 2 "EVIDENCE_WRITE_FAIL"
chmod +w "./logs"

echo "---------------------------------------------------"
echo "🏁 測試矩陣執行完畢。"
