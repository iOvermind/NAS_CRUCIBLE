#!/bin/bash
set -u

if [ "$EUID" -ne 0 ]; then
    echo "❌ 錯誤: 必須以 root 身分執行"
    exit 2
fi

if [ -z "${TMUX:-}" ] && [ -z "${STY:-}" ] && [[ "${TERM:-}" != screen* ]] && [[ "${TERM:-}" != tmux* ]]; then
    echo "❌ 錯誤: 必須在 tmux 或 screen 內執行，避免連線中斷"
    echo "💡 提示: 如果你已經在 tmux 內，可能是 sudo 過濾了環境變數。請嘗試加上 -E: sudo -E ./crucible.sh"
    exit 2
fi

CRUCIBLE_LOG_DIR="${CRUCIBLE_LOG_DIR:-./burnin_logs_$(date +%Y%m%d_%H%M%S)}"
CRUCIBLE_POLICY_DIR="${CRUCIBLE_POLICY_DIR:-./policies}"

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
mkdir -p "$CRUCIBLE_LOG_DIR"
MANIFEST="$CRUCIBLE_LOG_DIR/device_manifest.json"

if [ "$#" -eq 0 ]; then
    echo "❌ 錯誤: 請指定要測試的區塊裝置 (例如: ./crucible.sh sdb sdc)"
    exit 2
fi

echo "=========================================="
echo "    Preflight Check (起飛前死角排查)      "
echo "=========================================="

devices_json="[]"

for dev in "$@"; do
    if [ ! -b "/dev/$dev" ]; then
        echo "❌ /dev/$dev 不存在或不是區塊裝置"
        exit 2
    fi
    
    # check mount
    if lsblk -n -o MOUNTPOINT "/dev/$dev" | grep -q "[a-zA-Z0-9]"; then
        echo "❌ /dev/$dev 正在使用中 (已掛載)"
        exit 2
    fi
    
    # query smartctl
    smart_info=$(smartctl -j -i "/dev/$dev" 2>/dev/null)
    if [ -z "$smart_info" ]; then
        echo "❌ 無法讀取 /dev/$dev 的 SMART 資訊"
        exit 2
    fi
    
    serial=$(echo "$smart_info" | jq -r '.serial_number // "UNKNOWN"')
    protocol=$(echo "$smart_info" | jq -r '.device.protocol // "UNKNOWN"')
    model=$(echo "$smart_info" | jq -r '.model_name // "UNKNOWN"')
    is_ssd=$(echo "$smart_info" | jq -r '.rotation_rate == 0')
    
    class="UNKNOWN"
    if [ "$protocol" = "ATA" ]; then
        if [ "$is_ssd" = "true" ]; then class="SATA_SSD"
        else class="SATA_HDD"; fi
    elif [ "$protocol" = "SCSI" ]; then
        if [ "$is_ssd" = "true" ]; then class="SAS_SSD"
        else class="SAS_HDD"; fi
    fi
    
    policy_file="$CRUCIBLE_POLICY_DIR/${class,,}.json"
    if [ -f "$policy_file" ]; then
        decision="ALLOW"
        prof=$(jq -r '.execution_profile' "$policy_file")
        printf "✅ /dev/%-4s | %-8s | %-15s | SN: %-15s (Profile: %s)\n" "$dev" "$class" "$model" "$serial" "$prof"
    else
        decision="BLOCK"
        policy_file=""
        printf "❌ /dev/%-4s | %-8s | %-15s | SN: %-15s (無對應 Policy)\n" "$dev" "$class" "$model" "$serial"
    fi
    
    dev_obj=$(jq -n \
        --arg dev "$dev" \
        --arg sn "$serial" \
        --arg proto "$protocol" \
        --arg cls "$class" \
        --arg dec "$decision" \
        --arg pol "$policy_file" \
        '{device: $dev, serial: $sn, protocol: $proto, class: $cls, decision: $dec, policy_path: $pol}')
    devices_json=$(echo "$devices_json" | jq ". + [$dev_obj]")
done

echo "{\"devices\": $devices_json}" > "$MANIFEST"

echo ""
echo "⚠️ 警告：即將執行破壞性測試。確認以上皆為「非線上」新碟。"
read -rp "確定抹除請輸入 YES: " confirm
if [ "$confirm" != "YES" ]; then
    echo "使用者取消。"
    exit 130
fi

echo "[$(date '+%Y-%m-%d %H:%M')] 🚀 測試已啟動。進度與結果將即時更新於 $CRUCIBLE_LOG_DIR"
"$SCRIPT_DIR/crucible_controller.sh" "$MANIFEST" "$CRUCIBLE_LOG_DIR"
CTRL_RC=$?

echo ""
echo "=========================================================================="
echo "                      BURN-IN FINAL RESULT                                "
echo "=========================================================================="

num_devs=$(jq '.devices | length' "$MANIFEST")
for (( i=0; i<$num_devs; i++ )); do
    dev_obj=$(jq -c ".devices[$i]" "$MANIFEST")
    dev=$(jq -r '.device' <<< "$dev_obj")
    serial=$(jq -r '.serial' <<< "$dev_obj")
    decision=$(jq -r '.decision' <<< "$dev_obj")
    
    if [ "$decision" != "ALLOW" ]; then
        printf "/dev/%-4s | SN: %-15s | ❌ BLOCKED\n" "$dev" "$serial"
        continue
    fi
    
    exec_file="$CRUCIBLE_LOG_DIR/exec_record_${serial}.json"
    verdict_file="$CRUCIBLE_LOG_DIR/${serial}_verdict_evidence.json"
    
    if [ ! -f "$verdict_file" ]; then
        exec_status=$(jq -r '.execution.status // "UNKNOWN"' "$exec_file" 2>/dev/null)
        printf "/dev/%-4s | SN: %-15s | ❌ FAIL [未完成，狀態: %s]\n" "$dev" "$serial" "$exec_status"
        continue
    fi
    
    v_pass=$(jq -r '.observation.overall_pass // false' "$verdict_file")
    v_reasons=$(jq -r '.observation.reasons | join(", ")' "$verdict_file")
    v_bt=$(jq -r '.observation.baseline_temp' "$verdict_file")
    v_ft=$(jq -r '.observation.final_temp' "$verdict_file")
    v_rc=$(jq -r '.observation.smartctl_rc' "$verdict_file")
    
    if [ "$v_pass" == "true" ]; then
        printf "/dev/%-4s | SN: %-15s | ✅ PASS (RC:%s, Temp: %sC -> %sC)\n" "$dev" "$serial" "$v_rc" "$v_bt" "$v_ft"
    else
        printf "/dev/%-4s | SN: %-15s | ❌ FAIL %s (RC:%s, Temp: %sC -> %sC)\n" "$dev" "$serial" "$v_reasons" "$v_rc" "$v_bt" "$v_ft"
    fi
done
echo "=========================================================================="

exit $CTRL_RC
