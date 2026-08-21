#!/bin/bash
# =========================================================================
# TrueNAS SATA HDD Destructive Burn-in & Acceptance Script
# 適用對象: 全新/二手 SATA 傳統硬碟 (不適用 SAS / NVMe)
# =========================================================================

DRIVES=("$@")
TIMESTAMP=$(date +"%Y%m%d_%H%M%S")
LOG_DIR="/root/burnin_logs_$TIMESTAMP"

if [ ${#DRIVES[@]} -eq 0 ]; then
    echo "❌ 錯誤：未提供硬碟代號！"
    exit 1
fi

# ==========================================
# Preflight 0: 環境與權限
# ==========================================
if [ "$EUID" -ne 0 ]; then
    echo "❌ 錯誤：必須以 root 權限執行此破壞性腳本。"
    exit 1
fi

if [ -z "$TMUX" ] && [ -z "$STY" ]; then
    echo "⚠️ 警告：必須在 tmux 或 screen 環境下執行，避免斷線導致進度全毀！"
    exit 1
fi

MISSING_PKGS=""
if ! command -v jq &> /dev/null; then MISSING_PKGS+=" jq"; fi
if ! command -v smartctl &> /dev/null; then MISSING_PKGS+=" smartmontools"; fi
if ! command -v badblocks &> /dev/null; then MISSING_PKGS+=" e2fsprogs"; fi

if [ -n "$MISSING_PKGS" ]; then
    echo "❌ 靠背，缺乏必要的套件！請複製並執行以下指令安裝："
    echo "sudo apt update && sudo apt install$MISSING_PKGS"
    exit 1
fi

echo "=========================================="
echo "    Preflight Check (起飛前死角排查)      "
echo "=========================================="
mkdir -p "$LOG_DIR"

declare -A SEEN
declare -A SN
declare -A MODEL
declare -A P1_STATUS
declare -A BB_STATUS
declare -A P3_STATUS

# ==========================================
# Preflight 1: 實體綁定與 ZFS 佔用排查
# ==========================================
for dev in "${DRIVES[@]}"; do
    if [[ -n "${SEEN[$dev]}" ]]; then
        echo "❌ 錯誤：重複指定硬碟 /dev/$dev"
        exit 1
    fi
    SEEN["$dev"]=1

    if [ ! -b "/dev/$dev" ]; then
        echo "❌ 錯誤：/dev/$dev 不存在或不是區塊裝置。"
        exit 1
    fi

    if lsblk -no MOUNTPOINTS "/dev/$dev" | grep -q "\S" || findmnt "/dev/$dev" >/dev/null 2>&1; then
        echo "❌ 錯誤：/dev/$dev 目前被 OS 掛載！"
        exit 1
    fi

    if lsblk -f "/dev/$dev" | grep -iq "zfs_member" || zpool status -P | grep -qE "/dev/$dev\b"; then
        echo "❌ 致命錯誤：/dev/$dev 出現於活躍的 ZFS Pool，拒絕執行！"
        exit 1
    fi

    _model=$(smartctl -i "/dev/$dev" | grep -i "Device Model" | awk -F: '{print $2}' | xargs)
    _sn=$(smartctl -i "/dev/$dev" | grep -i "Serial Number" | awk -F: '{print $2}' | xargs)
    
    if [ -z "$_sn" ]; then
        echo "❌ 錯誤：無法從 /dev/$dev 讀取 Serial Number，通訊異常。"
        exit 1
    fi
    MODEL["$dev"]=${_model:-"UNKNOWN"}
    SN["$dev"]=$_sn
done

echo "✅ Preflight 通過。即將全盤抹除以下磁碟："
for dev in "${DRIVES[@]}"; do
    echo "/dev/$dev  |  ${MODEL[$dev]}  |  SN: ${SN[$dev]}"
done
read -p "確認以上皆為「非線上」新碟，確定抹除請輸入 YES: " confirm
if [ "$confirm" != "YES" ]; then echo "已取消。"; exit 1; fi

# ==========================================
# 輔助函數區
# ==========================================
dump_and_validate_json() {
    local dev=$1
    local out_file=$2
    
    smartctl -j -x "/dev/$dev" > "$out_file" 2>/dev/null
    
    if ! jq empty "$out_file" >/dev/null 2>&1; then
        return 1
    fi
    
    return 0
}

# 把它塞在腳本輔助函數區
parse_smartctl_rc() {
    local rc=$1
    if [ -z "$rc" ] || [ "$rc" -eq 0 ]; then echo "0"; return; fi
    local msg=""
    (( rc & 1 )) && msg+="CmdFail,"
    (( rc & 2 )) && msg+="DevOpen,"
    (( rc & 4 )) && msg+="Chksum,"
    (( rc & 8 )) && msg+="DiskFail,"
    (( rc & 16 )) && msg+="PreFail,"
    (( rc & 32 )) && msg+="PastFail,"
    (( rc & 64 )) && msg+="ErrLog,"
    (( rc & 128 )) && msg+="SelfTest,"
    echo "${msg%,}" # 拔掉最後一個逗號
}

wait_all_smart() {
    local phase_name=$1
    echo "等待 $phase_name SMART Long Test (每 5 分鐘輪詢)..."
    
    # 狀態定義: 0=RUNNING, 1=DONE, 2=ERROR
    declare -A FLAG
    for dev in "${DRIVES[@]}"; do FLAG["$dev"]=0; done

    while true; do
        local all_finished=true
        for dev in "${DRIVES[@]}"; do
            if [ "${FLAG[$dev]}" -ne 0 ]; then continue; fi
            
            local output
            if ! output=$(smartctl -c "/dev/$dev" 2>/dev/null); then
                echo "⚠️ /dev/$dev 通訊失敗，標記為 ERROR 停止輪詢。"
                FLAG["$dev"]=2
                continue
            fi
            
            # 嚴格驗證：必須確實讀到狀態欄位
            if ! echo "$output" | grep -qi "Self-test execution status"; then
                echo "⚠️ /dev/$dev 無法解析 SMART self-test 狀態，標記為 ERROR。"
                FLAG["$dev"]=2
                continue
            fi

            # 根據字串判定進度
            if echo "$output" | grep -qi "in progress"; then
                all_finished=false
            else
                FLAG["$dev"]=1
            fi
        done
        
        if $all_finished; then break; fi
        sleep 300
    done
    
    # 將 ERROR 狀態回傳給外部的全域變數
    for dev in "${DRIVES[@]}"; do
        if [ "${FLAG[$dev]}" -eq 2 ]; then
            if [ "$phase_name" == "Phase 1" ]; then P1_STATUS["$dev"]="FAIL_COMM"; fi
            if [ "$phase_name" == "Phase 3" ]; then P3_STATUS["$dev"]="FAIL_COMM"; fi
        fi
    done
}

verify_selftest() {
    local dev=$1
    if smartctl -l selftest "/dev/$dev" | grep "^# 1 " | grep -iq "Completed without error"; then
        echo "PASS"
    else
        echo "FAIL"
    fi
}

# ==========================================
# Phase 0: Baseline
# ==========================================
echo -e "\n=== Phase 0: 基準快照 ==="
for dev in "${DRIVES[@]}"; do
    serial=${SN[$dev]}
    if ! dump_and_validate_json "$dev" "$LOG_DIR/${serial}_baseline.json"; then
        echo "❌ /dev/$dev ($serial) Baseline JSON 擷取或解析失敗！"
        exit 1
    fi
done

# ==========================================
# Phase 1: 首次 SMART Long
# ==========================================
echo -e "\n=== Phase 1: 啟動首次 SMART Long Test ==="
for dev in "${DRIVES[@]}"; do
    serial=${SN[$dev]}
    if ! smartctl -t long "/dev/$dev" > "$LOG_DIR/${serial}_p1_start.log" 2>&1; then
        echo "❌ /dev/$dev ($serial) P1 啟動失敗"
        P1_STATUS["$dev"]="FAIL_START"
    fi
done

wait_all_smart "Phase 1"

for dev in "${DRIVES[@]}"; do
    if [ -z "${P1_STATUS[$dev]}" ]; then
        P1_STATUS["$dev"]=$(verify_selftest "$dev")
    fi
    smartctl -l selftest "/dev/$dev" > "$LOG_DIR/${SN[$dev]}_p1_selftest.txt"
done

# ==========================================
# Phase 2: Destructive Burn-in
# ==========================================
echo -e "\n=== Phase 2: badblocks -wsv 全盤覆寫 (這會跑好幾天) ==="
declare -A PIDS
for dev in "${DRIVES[@]}"; do
    serial=${SN[$dev]}
    badblocks -wsv -b 4096 "/dev/$dev" > "$LOG_DIR/${serial}_badblocks.log" 2>&1 &
    PIDS["$dev"]=$!
done

for dev in "${DRIVES[@]}"; do
    serial=${SN[$dev]}
    if wait "${PIDS[$dev]}"; then
        BB_STATUS["$dev"]="PASS"
    else
        BB_STATUS["$dev"]="FAIL"
        echo "❌ /dev/$dev ($serial) badblocks 發生錯誤 (Exit 非 0)"
    fi
done

# ==========================================
# Phase 3: 最終 SMART Long
# ==========================================
echo -e "\n=== Phase 3: 啟動最終 SMART Long Test ==="
for dev in "${DRIVES[@]}"; do
    serial=${SN[$dev]}
    if ! smartctl -t long "/dev/$dev" > "$LOG_DIR/${serial}_p3_start.log" 2>&1; then
        echo "❌ /dev/$dev ($serial) P3 啟動失敗"
        P3_STATUS["$dev"]="FAIL_START"
    fi
done

wait_all_smart "Phase 3"

for dev in "${DRIVES[@]}"; do
    if [ -z "${P3_STATUS[$dev]}" ]; then
        P3_STATUS["$dev"]=$(verify_selftest "$dev")
    fi
    smartctl -l selftest "/dev/$dev" > "$LOG_DIR/${SN[$dev]}_p3_selftest.txt"
done

# ==========================================
# Phase 4: Final 嚴格驗收 (Fail-Closed 解析)
# ==========================================
echo -e "\n=== Phase 4: 自動化判定結果 ==="
declare -A FINAL_RESULT
OVERALL_PASS=true

for dev in "${DRIVES[@]}"; do
    serial=${SN[$dev]}
    base_json="$LOG_DIR/${serial}_baseline.json"
    final_json="$LOG_DIR/${serial}_final.json"
    REASON=""

    if ! dump_and_validate_json "$dev" "$final_json"; then
        FINAL_RESULT["$dev"]="FAIL [Final JSON 解析失敗]"
        OVERALL_PASS=false
        continue
    fi

    # 1. SMART Overall Health
    HEALTH=$(jq -r '.smart_status.passed' "$final_json")
    if [ "$HEALTH" != "true" ]; then REASON+="[SMART_Health=FAIL] "; fi

    # 2. 死亡指標 (Fail-Closed)
    REALLOC=$(jq -r '.ata_smart_attributes.table[]? | select(.id == 5) | .raw.value' "$final_json")
    PENDING=$(jq -r '.ata_smart_attributes.table[]? | select(.id == 197) | .raw.value' "$final_json")
    OFFLINE=$(jq -r '.ata_smart_attributes.table[]? | select(.id == 198) | .raw.value' "$final_json")
    
    BASE_CRC=$(jq -r '.ata_smart_attributes.table[]? | select(.id == 199) | .raw.value' "$base_json")
    FINAL_CRC=$(jq -r '.ata_smart_attributes.table[]? | select(.id == 199) | .raw.value' "$final_json")

    if ! [[ "$REALLOC" =~ ^[0-9]+$ ]]; then REASON+="[無ID_5數據] "; elif [ "$REALLOC" -ne 0 ]; then REASON+="[Realloc>0] "; fi
    if ! [[ "$PENDING" =~ ^[0-9]+$ ]]; then REASON+="[無ID_197數據] "; elif [ "$PENDING" -ne 0 ]; then REASON+="[Pending>0] "; fi
    if ! [[ "$OFFLINE" =~ ^[0-9]+$ ]]; then REASON+="[無ID_198數據] "; elif [ "$OFFLINE" -ne 0 ]; then REASON+="[Offline>0] "; fi
    
    if ! [[ "$FINAL_CRC" =~ ^[0-9]+$ ]] || ! [[ "$BASE_CRC" =~ ^[0-9]+$ ]]; then 
        REASON+="[無ID_199數據] "
    elif [ "$FINAL_CRC" -gt "$BASE_CRC" ]; then 
        REASON+="[CRC增加] "
    fi

    # 3. SMART Error Log 嚴格驗證
    BASE_ERR=$(jq -r '.ata_smart_error_log.summary.count // empty' "$base_json")
    FINAL_ERR=$(jq -r '.ata_smart_error_log.summary.count // empty' "$final_json")
    
    if ! [[ "$BASE_ERR" =~ ^[0-9]+$ ]] || ! [[ "$FINAL_ERR" =~ ^[0-9]+$ ]]; then
        REASON+="[ErrorLog解析異常] "
    elif [ "$FINAL_ERR" -gt "$BASE_ERR" ]; then
        REASON+="[新增ErrorLog] "
    fi

    # 4. 階段狀態
    if [ "${P1_STATUS[$dev]}" != "PASS" ]; then REASON+="[P1_異常:${P1_STATUS[$dev]}] "; fi
    if [ "${BB_STATUS[$dev]}" != "PASS" ]; then REASON+="[Badblocks_異常] "; fi
    if [ "${P3_STATUS[$dev]}" != "PASS" ]; then REASON+="[P3_異常:${P3_STATUS[$dev]}] "; fi

    BASE_TEMP=$(jq -r '.temperature.current // "N/A"' "$base_json")
    FINAL_TEMP=$(jq -r '.temperature.current // "N/A"' "$final_json")
    SMARTCTL_RC=$(jq -r '.smartctl.exit_status // empty' "$final_json")
    RC_TEXT=$(parse_smartctl_rc "$SMARTCTL_RC")

    if [ -z "$REASON" ]; then
        FINAL_RESULT["$dev"]="PASS (RC:$RC_TEXT, Temp: ${BASE_TEMP}C -> ${FINAL_TEMP}C)"
    else
        FINAL_RESULT["$dev"]="FAIL $REASON (RC:$RC_TEXT)"
        OVERALL_PASS=false
    fi
done

echo ""
echo "=========================================================================="
echo "                      BURN-IN FINAL RESULT (V5)                           "
echo "=========================================================================="
for dev in "${DRIVES[@]}"; do
    serial=${SN[$dev]}
    model=${MODEL[$dev]}
    printf "%-8s | %-15s | SN: %-15s | %s\n" "/dev/$dev" "$model" "$serial" "${FINAL_RESULT[$dev]}"
done
echo "=========================================================================="
if $OVERALL_PASS; then
    echo " RESULT: ✅ ALL PASS"
    echo " 本次 SATA HDD burn-in 所設定之測試與驗收條件全部通過。"
    echo " 可進入 TrueNAS Zpool 建池流程。"
else
    echo " RESULT: ❌ FAIL (部分或全部失敗)"
    echo " 請針對 FAIL 的硬碟檢查 $LOG_DIR 內的 JSON 與 log 檔案。"
fi
echo "=========================================================================="
