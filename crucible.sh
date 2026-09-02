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

# SCRIPT_DIR 必須先算出來：預設的 logs/ 與 policies/ 都要錨定在腳本所在
# 位置，不能用 ./ 相對於當前工作目錄。原本 `sudo -E /opt/NAS_CRUCIBLE/crucible.sh sdb`
# 從 $HOME 執行時，policy 會去 $HOME/policies 找，`[ -f "$policy_file" ]`
# 全部落空 -> 每顆碟都 decision=BLOCK -> controller 印「No allowed devices」
# 並 exit 0，工具回報成功卻一顆碟都沒測。
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

CRUCIBLE_LOG_DIR="${CRUCIBLE_LOG_DIR:-$SCRIPT_DIR/logs/$(date +%Y%m%d_%H%M%S)}"
CRUCIBLE_POLICY_DIR="${CRUCIBLE_POLICY_DIR:-$SCRIPT_DIR/policies}"

source "$SCRIPT_DIR/lib/device_probe.sh"
mkdir -p "$CRUCIBLE_LOG_DIR"
MANIFEST="$CRUCIBLE_LOG_DIR/device_manifest.json"

# Evidence 必須能回答「跑出這份結果的是哪一版程式碼」。ISO 建置時會在專案根目錄
# 產生 build_info.json；複製一份進 log dir，讓每個 log 目錄自我描述，
# 不必依賴外部對照表。commit 同時寫進 exec_record。
if [ -f "$SCRIPT_DIR/build_info.json" ]; then
    cp "$SCRIPT_DIR/build_info.json" "$CRUCIBLE_LOG_DIR/" 2>/dev/null || true
    CRUCIBLE_BUILD_COMMIT=$(jq -r '.commit // "unknown"' "$SCRIPT_DIR/build_info.json" 2>/dev/null)
    export CRUCIBLE_BUILD_COMMIT
fi

# --- Live 模式與 Boot Medium 識別 ---
# Live 開機時，承載本工具的那顆隨身碟自己也是一顆 block device，會出現在
# lsblk 的清單裡。抹掉它等於自殺，而且會連同跑到一半的 Evidence 一起銷毀。
# 反查失敗時不得當成「沒有開機碟」，必須退化為排除全部 removable 裝置。
# 見 docs/adr/0003。
LIVE_MODE=false
BOOT_MEDIUM=""
BOOT_MEDIUM_UNKNOWN=false
if is_live_environment; then
    LIVE_MODE=true
    if ! BOOT_MEDIUM=$(detect_boot_medium); then
        BOOT_MEDIUM=""
        BOOT_MEDIUM_UNKNOWN=true
    fi
fi

# 這顆碟是否因為身為開機媒體而必須被排除。回傳 0 = 必須排除。
dev_is_boot_excluded() {
    local d=$1
    [ -n "$BOOT_MEDIUM" ] && [ "$d" = "$BOOT_MEDIUM" ] && return 0
    [ "$BOOT_MEDIUM_UNKNOWN" = true ] && dev_is_removable "$d" && return 0
    return 1
}


# --- No-Persistence 警告 ---
# Evidence Store 建不起來時 (虛擬光碟開機、隨身碟無剩餘空間、分區表寫入失敗)，
# 證據只存在於記憶體，斷電即失。3-5 天的測試中途斷電還以為證據都在，是這個
# 降級模式唯一真正的風險 —— 因此在選碟畫面、確認前、以及最終結果都要講一次。
NOPERSIST_FLAG="${CRUCIBLE_NOPERSIST_FLAG:-/run/crucible/no-persistence}"
NOPERSIST_TAG=""
[ -f "$NOPERSIST_FLAG" ] && NOPERSIST_TAG=" [無持久化]"

persistence_banner() {
    [ -f "$NOPERSIST_FLAG" ] || return 0
    echo "=========================================================================="
    echo "⚠️  NO PERSISTENCE：本次測試的 Evidence 只存在於記憶體 (tmpfs)"
    echo "    原因：$(cat "$NOPERSIST_FLAG" 2>/dev/null)"
    echo "    斷電或重開機將失去全部證據。"
    echo "=========================================================================="
}
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
            # 不可用 `.rotation_rate == 0`：欄位缺漏時 null == 0 為 false，
            # SSD 會被誤判成 HDD 而套用破壞性 profile。jq 裡 0 是真值，
            # 所以 `// "ABSENT"` 能正確區分「值為 0」與「欄位不存在」。
            tui_rot=$(echo "$smart_info" | jq -r '.rotation_rate // "ABSENT"')

            tui_class=$(classify_device "$tui_protocol" "$tui_rot")
        else
            tui_serial="N/A"; tui_model="N/A"; tui_class="UNKNOWN"
        fi

        # 檢查掛載狀態與 ZFS 成員
        warnings=""
        if dev_is_boot_excluded "$dev_name"; then
            warnings="[BOOT] "
        fi
        if lsblk -n -o MOUNTPOINT "$dev_path" 2>/dev/null | grep -q "[a-zA-Z0-9]"; then
            warnings="${warnings}[MOUNTED] "
        fi
        # 整碟 pool 時 zpool 印的是 /dev/sdb1 而非 /dev/sdb，原本的 grep -Fxq
        # 全行比對永遠不命中，[ZFS] 警告在最常見的情境下從來不會顯示。
        dev_in_zpool "$(basename "$dev_path")"
        case $? in
            0) warnings="${warnings}[ZFS] " ;;
            2) warnings="${warnings}[ZFS?] " ;;
        esac
        if dev_has_holders "$(basename "$dev_path")"; then
            warnings="${warnings}[LVM/RAID] "
        fi
        # Signature 是 Live 模式下唯一還有效的「碟上有資料」證據，
        # 這裡先讓操作員在選碟畫面就看得到，避免勾了才被擋。
        dev_has_signature "$dev_name"
        case $? in
            0) warnings="${warnings}[DATA] " ;;
            2) warnings="${warnings}[DATA?] " ;;
        esac

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

    selection=$(whiptail --title "NAS_CRUCIBLE 硬碟選擇$NOPERSIST_TAG" \
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
persistence_banner

if [ "$LIVE_MODE" = true ]; then
    if [ -n "$BOOT_MEDIUM" ]; then
        echo "🔒 Live 模式：開機媒體 /dev/$BOOT_MEDIUM 及其所有分區一律排除"
    else
        echo "🔒 Live 模式：無法反查開機媒體，退化為排除全部 removable 裝置"
    fi
fi

# Admission 的失敗粒度是「單顆」而非「整批」：manifest 的 decision 欄位、
# controller 的 ALLOW 過濾、最終表格的 BLOCKED 列印本來就都支援部分放行，
# 只是舊版在寫出 manifest 之前就 exit 2，讓這套設計從未被用到。機房裡一次
# 插 8 顆碟，不該因為第 3 顆有簽章就整批重來。
devices_json="[]"

for dev in "$@"; do
    decision="ALLOW"; reason=""; overridable=false
    serial="UNKNOWN"; protocol="UNKNOWN"; model="UNKNOWN"; class="UNKNOWN"; policy_file=""

    # --- 1. 裝置歸屬與佔用 (執行時狀態；Live 模式下這幾項多半會全部落空) ---
    if [ ! -b "/dev/$dev" ]; then
        decision="BLOCK"; reason="NOT_A_BLOCK_DEVICE"
    elif dev_is_boot_excluded "$dev"; then
        decision="BLOCK"
        if [ -n "$BOOT_MEDIUM" ] && [ "$dev" = "$BOOT_MEDIUM" ]; then
            reason="BOOT_MEDIUM"
        else
            reason="REMOVABLE_BOOT_UNKNOWN"
        fi
    elif lsblk -n -o MOUNTPOINT "/dev/$dev" | grep -q "[a-zA-Z0-9]"; then
        decision="BLOCK"; reason="MOUNTED"
    else
        dev_in_zpool "$dev"
        case $? in
            0) decision="BLOCK"; reason="ZFS_POOL_MEMBER" ;;
            2) decision="BLOCK"; reason="ZFS_QUERY_FAILED" ;;
        esac
        if [ "$decision" = "ALLOW" ] && dev_has_holders "$dev"; then
            decision="BLOCK"; reason="STORAGE_HOLDERS"
        fi
    fi

    # --- 2. 身分讀取 (即使已 BLOCK 也盡量讀，報表才指認得出是哪一顆碟) ---
    if [ -b "/dev/$dev" ]; then
        smart_info=$(smartctl -j -i "/dev/$dev" 2>/dev/null)
        if [ -n "$smart_info" ] && jq empty <<<"$smart_info" >/dev/null 2>&1; then
            serial=$(jq -r '.serial_number // "UNKNOWN"' <<<"$smart_info")
            protocol=$(jq -r '.device.protocol // "UNKNOWN"' <<<"$smart_info")
            model=$(jq -r '.model_name // "UNKNOWN"' <<<"$smart_info")
            # 見 lib/device_probe.sh：rotation_rate 缺漏時不得預設成 HDD。
            rot=$(jq -r '.rotation_rate // "ABSENT"' <<<"$smart_info")
            class=$(classify_device "$protocol" "$rot")
        elif [ "$decision" = "ALLOW" ]; then
            decision="BLOCK"; reason="IDENTITY_UNREADABLE"
        fi
    fi

    # --- 3. Policy 匹配 (先於 Signature，Override 才只會出現在真正跑得動的碟上) ---
    if [ "$decision" = "ALLOW" ]; then
        policy_file="$CRUCIBLE_POLICY_DIR/${class,,}.json"
        if [ ! -f "$policy_file" ]; then
            decision="BLOCK"; reason="NO_POLICY"; policy_file=""
        fi
    fi

    # --- 4. Signature：Live 模式下唯一還有效的「碟上有資料」防線 ---
    #     這是全系統唯一可被 Override 解除的一條。見 docs/adr/0001。
    if [ "$decision" = "ALLOW" ]; then
        dev_has_signature "$dev"
        case $? in
            0) decision="BLOCK"; reason="HAS_DATA"; overridable=true ;;
            2) decision="BLOCK"; reason="SIGNATURE_QUERY_FAILED" ;;
        esac
    fi

    dev_obj=$(jq -n \
        --arg dev "$dev" --arg sn "$serial" --arg proto "$protocol" \
        --arg cls "$class" --arg mdl "$model" --arg dec "$decision" \
        --arg rsn "$reason" --arg pol "$policy_file" --argjson ovr "$overridable" \
        '{device:$dev, serial:$sn, protocol:$proto, class:$cls, model:$mdl,
          decision:$dec, block_reason:$rsn, overridable:$ovr, overridden:false,
          policy_path:$pol}')
    devices_json=$(jq ". + [$dev_obj]" <<<"$devices_json")
done

# --- 序號重複：兩顆都擋 ---
# runner 的狀態機與證據檔以序號命名 (exec_record_<sn>.json / <sn>_<phase>_evidence.json)。
# 兩顆同序號的碟 (常見於廉價 USB/SAS 橋接器) 會互相覆寫證據，事後無法分辨
# 哪份 Evidence 屬於哪顆碟 —— 因此兩顆都不放行，而不是整批中止。
devices_json=$(jq '
    (reduce .[] as $d ({}; .[$d.serial] = ((.[$d.serial] // 0) + 1))) as $count
    | map(if $count[.serial] > 1
          then .decision="BLOCK" | .block_reason="DUPLICATE_SERIAL"
               | .overridable=false | .policy_path=""
          else . end)' <<<"$devices_json")

# --- Override：逐碟輸入序號才能解除 Signature 造成的封鎖 ---
# 不提供全域 --force。單一旗標關掉整條防線，正是本專案已經修過數次的
# fail-open 形狀；逐碟輸入序號則讓「解除」的成本與風險成正比。
# 非互動情境 (stdin 不是 tty) 一律維持封鎖，避免這條路徑被寫進某人的
# 排程腳本變成預設值。
ovr_total=$(jq '[.[] | select(.overridable)] | length' <<<"$devices_json")
if [ "$ovr_total" -gt 0 ]; then
    echo ""
    if [ -t 0 ]; then
        echo "⚠️  下列硬碟偵測到既有資料簽章 (檔案系統 / ZFS / LVM / mdraid 成員)。"
        echo "    確定要抹除的話，請逐碟輸入該碟序號解除封鎖；直接 Enter 維持封鎖。"
        dev_total=$(jq 'length' <<<"$devices_json")
        for (( i=0; i<dev_total; i++ )); do
            jq -e --argjson i "$i" '.[$i].overridable' <<<"$devices_json" >/dev/null || continue
            o_dev=$(jq -r --argjson i "$i" '.[$i].device' <<<"$devices_json")
            o_sn=$(jq -r --argjson i "$i" '.[$i].serial' <<<"$devices_json")
            [ "$o_sn" = "UNKNOWN" ] && continue
            read -rp "    /dev/$o_dev (SN: $o_sn) 輸入序號以解除: " ans
            if [ "$ans" = "$o_sn" ]; then
                devices_json=$(jq --argjson i "$i" \
                    '.[$i].decision="ALLOW" | .[$i].block_reason="" | .[$i].overridden=true' \
                    <<<"$devices_json")
                echo "    ⚠️  /dev/$o_dev 已解除封鎖 (OVERRIDE)"
            else
                echo "    ⏭  /dev/$o_dev 維持封鎖"
            fi
        done
    else
        echo "⚠️  有硬碟因既有資料簽章被擋下。Override 僅在互動情境提供，"
        echo "    非互動執行一律維持封鎖。"
    fi
fi

# --- 結果彙整 ---
echo ""
num_devs=$(jq 'length' <<<"$devices_json")
allow_count=0
for (( i=0; i<num_devs; i++ )); do
    d=$(jq -c --argjson i "$i" '.[$i]' <<<"$devices_json")
    r_dev=$(jq -r '.device' <<<"$d");  r_cls=$(jq -r '.class' <<<"$d")
    r_mdl=$(jq -r '.model' <<<"$d");   r_sn=$(jq -r '.serial' <<<"$d")
    r_dec=$(jq -r '.decision' <<<"$d"); r_rsn=$(jq -r '.block_reason' <<<"$d")
    r_ovr=$(jq -r '.overridden' <<<"$d"); r_pol=$(jq -r '.policy_path' <<<"$d")
    if [ "$r_dec" = "ALLOW" ]; then
        allow_count=$((allow_count + 1))
        prof=$(jq -r '.execution_profile' "$r_pol" 2>/dev/null)
        if [ "$r_ovr" = "true" ]; then
            printf "⚠️  /dev/%-4s | %-8s | %-15s | SN: %-15s (Profile: %s, OVERRIDE)\n" \
                "$r_dev" "$r_cls" "$r_mdl" "$r_sn" "$prof"
        else
            printf "✅ /dev/%-4s | %-8s | %-15s | SN: %-15s (Profile: %s)\n" \
                "$r_dev" "$r_cls" "$r_mdl" "$r_sn" "$prof"
        fi
    else
        printf "❌ /dev/%-4s | %-8s | %-15s | SN: %-15s (BLOCKED: %s)\n" \
            "$r_dev" "$r_cls" "$r_mdl" "$r_sn" "$r_rsn"
    fi
done

# manifest 一律寫出，包含被擋下的碟與原因：被擋本身就是需要留存的判定紀錄。
jq -n --argjson d "$devices_json" '{devices: $d}' > "$MANIFEST"

if [ "$allow_count" -eq 0 ]; then
    echo ""
    echo "❌ 沒有任何硬碟通過 admission，不執行測試。"
    echo "   判定紀錄已保存於 $MANIFEST"
    exit 1
fi

echo ""
persistence_banner
echo "⚠️ 警告：即將對上列 $allow_count 顆硬碟執行破壞性測試。確認皆為「非線上」碟。"
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
    overridden=$(jq -r '.overridden // false' <<< "$dev_obj")
    ovr_tag=""; [ "$overridden" = "true" ] && ovr_tag=" (OVERRIDE)"
    
    if [ "$decision" != "ALLOW" ]; then
        block_reason=$(jq -r '.block_reason // ""' <<< "$dev_obj")
        printf "/dev/%-4s | SN: %-15s | ❌ BLOCKED [%s]\n" "$dev" "$serial" "$block_reason"
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
        printf "/dev/%-4s | SN: %-15s | ✅ PASS%s (RC:%s, Temp: %sC -> %sC)\n" "$dev" "$serial" "$ovr_tag" "$v_rc" "$v_bt" "$v_ft"
    else
        printf "/dev/%-4s | SN: %-15s | ❌ FAIL%s %s (RC:%s, Temp: %sC -> %sC)\n" "$dev" "$serial" "$ovr_tag" "$v_reasons" "$v_rc" "$v_bt" "$v_ft"
    fi
done
echo "=========================================================================="


# 最終摘要：即使 runner 全被 Global Abort 殺掉，這裡也會產出一份反映實況的報告。
if [ -x "$SCRIPT_DIR/report_renderer.sh" ]; then
    if "$SCRIPT_DIR/report_renderer.sh" "$CRUCIBLE_LOG_DIR" "${CRUCIBLE_REPORT_DIR:-$CRUCIBLE_LOG_DIR}" >/dev/null 2>&1; then
        echo "📄 摘要報告: ${CRUCIBLE_REPORT_DIR:-$CRUCIBLE_LOG_DIR}/summary.html"
    fi
fi
exit $CTRL_RC
