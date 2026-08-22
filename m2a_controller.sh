#!/bin/bash
# =========================================================================
# 模組: M2A Controller (Admission, PGID 隔離與 Global Abort 聚合)
# =========================================================================

MANIFEST_FILE="./test_manifest.json"
DECISIONS_FILE="./test_decisions.json"
mkdir -p "./logs"
rm -f ./logs/*.json

# =========================================================
# 🧪 建立假資料與壓力測試變數
# =========================================================
cat <<EOF > "$DECISIONS_FILE"
{
  "SN-PASS-01":   { "decision": "ALLOW", "policy": {"name": "HDD_BURN", "version": "1.0", "execution_profile": "HDD_FULL_BURNIN"} },
  "SN-LOCAL-02":  { "decision": "ALLOW", "policy": {"name": "HDD_BURN", "version": "1.0", "execution_profile": "HDD_FULL_BURNIN"} },
  "SN-INFRA-03":  { "decision": "ALLOW", "policy": {"name": "HDD_BURN", "version": "1.0", "execution_profile": "HDD_FULL_BURNIN"} },
  "SN-NO-EVD-04": { "decision": "ALLOW", "policy": {"name": "HDD_BURN", "version": "1.0", "execution_profile": "HDD_FULL_BURNIN"} },
  "SN-BAD-SCH-05":{ "decision": "ALLOW", "policy": {"name": "HDD_BURN", "version": "1.0", "execution_profile": "HDD_FULL_BURNIN"} },
  "SN-WRONG-06":  { "decision": "ALLOW", "policy": {"name": "SSD_BURN", "version": "1.0", "execution_profile": "SSD_FULL_BURNIN"} }
}
EOF
cat <<EOF > "$MANIFEST_FILE"
{
  "SN-PASS-01":   { "identity": { "device_handle": "sda", "serial": "SN-PASS-01" } },
  "SN-LOCAL-02":  { "identity": { "device_handle": "sdb", "serial": "SN-LOCAL-02" } },
  "SN-INFRA-03":  { "identity": { "device_handle": "sdc", "serial": "SN-INFRA-03" } },
  "SN-NO-EVD-04": { "identity": { "device_handle": "sdd", "serial": "SN-NO-EVD-04" } },
  "SN-BAD-SCH-05":{ "identity": { "device_handle": "sde", "serial": "SN-BAD-SCH-05" } },
  "SN-WRONG-06":  { "identity": { "device_handle": "sdf", "serial": "SN-WRONG-06" } }
}
EOF

# 將這些變數 Export 出去，讓 hdd_runner 裡的 Mock Adapter 讀得到
export SIM_SN_LOCAL_02_badblocks_RC=1
export SIM_SN_INFRA_03_smart_long_1_RC=2
export SIM_SN_NO_EVD_04_baseline_snapshot_NO_EVD=true
export SIM_SN_BAD_SCH_05_precheck_BAD_SCHEMA=true

record_admission_denied() {
    local sn=$1
    local rsn=$2
    local exp=$3
    local act=$4
    jq --arg sn "$sn" --arg rsn "$rsn" --arg exp "$exp" --arg act "$act" \
       '.[$sn].admission = {
          "decision": "DENIED",
          "reason": $rsn,
          "expected": $exp,
          "actual": $act
        }' "$DECISIONS_FILE" > "${DECISIONS_FILE}.tmp" && mv "${DECISIONS_FILE}.tmp" "$DECISIONS_FILE"
}

# =========================================================
# 🚦 行控中心主迴圈
# =========================================================
set -m
declare -A ACTIVE_PIDS
declare -A ACTIVE_PGIDS
GLOBAL_ABORT=false
ANY_LOCAL_FAILURE=false
CONTROLLER_RC=0

trap 'echo -e "\n🚨 操作員 SIGINT..."; trigger_global_abort 130' INT
trap 'echo -e "\n🚨 系統 SIGTERM..."; trigger_global_abort 143' TERM

trigger_global_abort() {
    local rc=$1
    if [ "$GLOBAL_ABORT" != "true" ]; then
        GLOBAL_ABORT=true
        CONTROLLER_RC=$rc
        echo "   -> 廣播 SIGTERM 給所有 Runner PGID..."
        for pid in "${!ACTIVE_PIDS[@]}"; do
            local pgid="${ACTIVE_PGIDS[$pid]}"
            [ -n "$pgid" ] && kill -TERM -- "-$pgid" 2>/dev/null
        done
    fi
}

echo "=========================================="
echo " 🚦 Phase 2: Admission & Dispatching"
echo "=========================================="

while IFS= read -r sn; do
    dev=$(jq -r --arg sn "$sn" '.[$sn].identity.device_handle // "UNKNOWN"' "$MANIFEST_FILE")
    dec_obj=$(jq -c --arg sn "$sn" '.[$sn] // empty' "$DECISIONS_FILE")
    
    decision=$(jq -r '.decision // "BLOCK"' <<< "$dec_obj")
    prof=$(jq -r '.policy.execution_profile // "NONE"' <<< "$dec_obj")
    pol_name=$(jq -r '.policy.name // "UNKNOWN"' <<< "$dec_obj")
    pol_ver=$(jq -r '.policy.version // "UNKNOWN"' <<< "$dec_obj")

    echo "📋 檢核: /dev/$dev (SN: $sn)"
    
    if [ "$decision" == "ALLOW" ]; then
        if [ "$prof" == "HDD_FULL_BURNIN" ]; then
            echo "   ✅ 入場核准。啟動獨立 Runner Process..."
            # 透過 setsid 將 Runner 與 Controller 在程序樹上徹底切割
            setsid ./hdd_runner.sh "$sn" "$dev" "$prof" "$pol_name" "$pol_ver" &
            pid=$!
            pgid=$(ps -o pgid= -p "$pid" | grep -Eo '[0-9]+' | head -n1)
            [ -z "$pgid" ] && pgid=$pid
            ACTIVE_PIDS["$pid"]="$sn"
            ACTIVE_PGIDS["$pid"]="$pgid"
        else
            echo "   ❌ 拒絕入場。Profile 錯誤。"
            record_admission_denied "$sn" "EXECUTION_PROFILE_MISMATCH" "HDD_FULL_BURNIN" "$prof"
        fi
    fi
done < <(jq -r 'keys[]' "$MANIFEST_FILE")

echo "=========================================="
echo " 📡 Controller: 等待子程序結束..."
echo "=========================================="

while [ ${#ACTIVE_PIDS[@]} -gt 0 ]; do
    wait -n 2>/dev/null
    
    for pid in "${!ACTIVE_PIDS[@]}"; do
        if ! kill -0 "$pid" 2>/dev/null; then
            sn="${ACTIVE_PIDS[$pid]}"
            wait "$pid" 2>/dev/null
            rc=$?
            unset ACTIVE_PIDS["$pid"]
            unset ACTIVE_PGIDS["$pid"]

            echo "📊 [Controller] Runner $sn 結束 (RC: $rc)"

            if [ $rc -eq 1 ]; then
                echo "   -> 偵測到單機任務失敗 (LOCAL FAIL)。"
                ANY_LOCAL_FAILURE=true
            elif [[ $rc -eq 2 || $rc -eq 130 || $rc -eq 143 ]]; then
                if [ "$GLOBAL_ABORT" != "true" ]; then
                    echo "🚨 偵測到基礎設施崩潰或中斷信號 (來自 $sn, RC=$rc)！"
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
elif [ "$ANY_LOCAL_FAILURE" == "true" ]; then
    echo "⚠️ Controller: 執行完畢，但包含單機失敗 (ONE_OR_MORE_LOCAL_FAILURES)。"
    exit 1
else
    echo "🎉 Controller: 所有任務完美收尾 (ALL_COMPLETED_SUCCESSFULLY)。"
    exit 0
fi
