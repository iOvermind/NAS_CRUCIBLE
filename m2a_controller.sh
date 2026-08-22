#!/bin/bash
# =========================================================================
# 模組: M2A Controller (實體 I/O 派發與 Global Abort 行控中心)
# =========================================================================

# 1. Root 與 依賴防護網 (Dependency Gate)
if [ "$EUID" -ne 0 ]; then
    echo "❌ 致命錯誤：必須以 root 權限執行此破壞性工具！"
    exit 2
fi

for cmd in smartctl jq lsblk findmnt zpool setsid ps; do
    command -v "$cmd" >/dev/null 2>&1 || {
        echo "❌ 致命錯誤：系統缺少必要依賴套件 [$cmd]！"
        exit 2
    }
done

MANIFEST_FILE="./device_manifest.json"
DECISIONS_FILE="./policy_decisions.json"
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
LOG_DIR="$SCRIPT_DIR/logs"
mkdir -p "$LOG_DIR"

if [ ! -f "$MANIFEST_FILE" ] || [ ! -f "$DECISIONS_FILE" ]; then
    echo "❌ 找不到 Manifest 或 Decisions 檔案，請確認 M1 前置作業已完成。"
    exit 1
fi

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
    protocol=$(jq -r --arg sn "$sn" '.[$sn].identity.protocol // "UNKNOWN"' "$MANIFEST_FILE")
    dec_obj=$(jq -c --arg sn "$sn" '.[$sn] // empty' "$DECISIONS_FILE")
    
    decision=$(jq -r '.decision // "BLOCK"' <<< "$dec_obj")
    prof=$(jq -r '.policy.execution_profile // "NONE"' <<< "$dec_obj")
    pol_name=$(jq -r '.policy.name // "UNKNOWN"' <<< "$dec_obj")
    pol_ver=$(jq -r '.policy.version // "UNKNOWN"' <<< "$dec_obj")

    echo "📋 檢核: /dev/$dev (SN: $sn, Protocol: $protocol)"
    
    case "$protocol" in
        ATA|SCSI) ;;
        *)
            echo "   ❌ 拒絕入場。不支援的 Protocol ($protocol)。"
            record_admission_denied "$sn" "UNSUPPORTED_OR_MISSING_PROTOCOL" "ATA_OR_SCSI" "$protocol"
            continue
            ;;
    esac

    if [ "$decision" == "ALLOW" ]; then
        if [ "$prof" == "HDD_FULL_BURNIN" ]; then
            echo "   ✅ 入場核准。啟動實體 Runner Process..."
            setsid "$SCRIPT_DIR/hdd_runner.sh" "$sn" "$dev" "$prof" "$pol_name" "$pol_ver" "$protocol" &
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
echo " 📡 Controller: 進入監聽迴圈..."
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
                echo "   -> $sn 發生單機任務失敗 (LOCAL FAIL)，其餘盤繼續。"
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
