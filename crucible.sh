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

CRUCIBLE_LOG_DIR="${CRUCIBLE_LOG_DIR:-./logs/$(date +%Y%m%d_%H%M%S)}"
CRUCIBLE_POLICY_DIR="${CRUCIBLE_POLICY_DIR:-./policies}"

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
mkdir -p "$CRUCIBLE_LOG_DIR"
MANIFEST="$CRUCIBLE_LOG_DIR/device_manifest.json"

# --- TUI: 互動式硬碟選擇 (無參數時自動啟動) ---
if [ "$#" -eq 0 ]; then
    command -v whiptail >/dev/null 2>&1 || {
        echo "❌ 錯誤: 互動模式需要 whiptail (apt install whiptail)"
        echo "💡 或者直接指定裝置: ./crucible.sh sdb sdc"
        exit 2
    }

    echo "🔍 掃描系統區塊裝置中..."

    checklist_args=()
    dev_count=0

    # 預先取得 ZFS Pool 狀態 (一次查詢，避免重複呼叫)
    zpool_out=""
    zpool_out=$(zpool status -LP 2>/dev/null) || true

    while IFS= read -r dev_path; do
        dev_name=$(basename "$dev_path")

        # 取得裝置大小 (human-readable)
        dev_size=$(lsblk -dnbo SIZE "$dev_path" 2>/dev/null | awk '{
            if ($1 >= 1099511627776) printf "%.1fT", $1/1099511627776
            else if ($1 >= 1073741824) printf "%.1fG", $1/1073741824
            else printf "%.0fM", $1/1048576
        }')

        # 透過 smartctl 取得身分資訊
        smart_info=$(smartctl -j -i "$dev_path" 2>/dev/null)
        if [ -n "$smart_info" ] && jq empty <<<"$smart_info" >/dev/null 2>&1; then
            tui_serial=$(echo "$smart_info" | jq -r '.serial_number // "N/A"')
            tui_model=$(echo "$smart_info" | jq -r '.model_name // "N/A"')
            tui_protocol=$(echo "$smart_info" | jq -r '.device.protocol // "UNKNOWN"')
            tui_is_ssd=$(echo "$smart_info" | jq -r '.rotation_rate == 0')

            tui_class="UNKNOWN"
            if [ "$tui_protocol" = "ATA" ]; then
                if [ "$tui_is_ssd" = "true" ]; then tui_class="SATA_SSD"; else tui_class="SATA_HDD"; fi
            elif [ "$tui_protocol" = "SCSI" ]; then
                if [ "$tui_is_ssd" = "true" ]; then tui_class="SAS_SSD"; else tui_class="SAS_HDD"; fi
            elif [ "$tui_protocol" = "NVMe" ]; then
                tui_class="NVME_SSD"
            fi
        else
            tui_serial="N/A"; tui_model="N/A"; tui_class="UNKNOWN"
        fi

        # 檢查掛載狀態與 ZFS 成員
        warnings=""
        if lsblk -n -o MOUNTPOINT "$dev_path" 2>/dev/null | grep -q "[a-zA-Z0-9]"; then
            warnings="[MOUNTED] "
        fi
        target_real=$(readlink -f "$dev_path")
        if [ -n "$zpool_out" ] && printf '%s\n' "$zpool_out" | awk '{print $1}' | grep -Fxq "$target_real"; then
            warnings="${warnings}[ZFS] "
        fi

        # 截斷過長的型號名稱以適配 whiptail 寬度
        if [ ${#tui_model} -gt 20 ]; then
            display_model="${tui_model:0:17}..."
        else
            display_model="$tui_model"
        fi

        label=$(printf "%s%s | %s | SN:%s | %s" "$warnings" "$dev_size" "$display_model" "$tui_serial" "$tui_class")
        checklist_args+=("$dev_name" "$label" "OFF")
        dev_count=$((dev_count + 1))
    done < <(lsblk -dnpo NAME,TYPE 2>/dev/null | awk '$2=="disk" {print $1}')

    if [ "$dev_count" -eq 0 ]; then
        echo "❌ 未偵測到任何可用的區塊裝置"
        exit 2
    fi

    selection=$(whiptail --title "NAS_CRUCIBLE 硬碟選擇" \
        --checklist "使用方向鍵移動，空白鍵勾選/取消，Enter 確認送出" \
        20 78 "$dev_count" \
        "${checklist_args[@]}" \
        3>&1 1>&2 2>&3) || {
        echo "使用者取消選擇。"
        exit 0
    }

    if [ -z "$selection" ]; then
        echo "未選擇任何裝置。"
        exit 0
    fi

    # whiptail 回傳格式: "sdb" "sdc" — 去除引號後設為位置參數
    selection=$(echo "$selection" | tr -d '"')
    # shellcheck disable=SC2086
    set -- $selection
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
    elif [ "$protocol" = "NVMe" ]; then
        class="NVME_SSD"
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
