#!/bin/bash
# =========================================================================
# Verdict Engine x NVME_SSD policy 迴歸測試 (不需要真實硬體)
#   用法: ./tests/test_verdict_nvme.sh
# =========================================================================
set -u
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
FX="$ROOT/tests/fixtures"
POLICY="$ROOT/policies/nvme_ssd.json"
ENGINE="$ROOT/verdict_engine.sh"
BASE="$FX/nvme_healthy.json"

pass=0; fail=0

# expect <期望rc> <final fixture> <期望出現在 reasons 的關鍵字|-> <說明>
expect() {
    local want_rc=$1 final=$2 want_reason=$3 desc=$4
    local out rc
    out=$("$ENGINE" "$BASE" "$FX/$final" "$POLICY"); rc=$?

    local ok=true
    [ "$rc" -eq "$want_rc" ] || ok=false
    if [ "$want_reason" = "-" ]; then
        # PASS 路徑：reasons 必須是嚴格的空陣列，不是 [""]
        [ "$(jq -c '.reasons' <<<"$out")" = "[]" ] || ok=false
    else
        jq -e --arg w "$want_reason" 'any(.reasons[]; contains($w))' <<<"$out" >/dev/null || ok=false
    fi

    if [ "$ok" = true ]; then
        printf "  ✅ %s\n" "$desc"; pass=$((pass+1))
    else
        printf "  ❌ %s (rc=%s, out=%s)\n" "$desc" "$rc" "$(jq -c '.reasons' <<<"$out")"; fail=$((fail+1))
    fi
}

echo "== Verdict Engine / NVME_SSD =="
expect 0 nvme_final_ok.json      -      "健康碟判定 PASS 且 reasons 為空陣列"
expect 1 nvme_unhealthy.json     "健康"  "smart_status.passed=false 判定 FAIL"
expect 1 nvme_media_errors.json  "媒體"  "media_errors>0 判定 FAIL"
expect 1 nvme_spare_low.json     "備用"  "available_spare<10 觸發 min 檢查 FAIL"
expect 1 nvme_critical_warn.json "警告"  "critical_warning!=0 判定 FAIL"
expect 1 nvme_worn.json          "壽命"  "percentage_used>90 判定 FAIL"
expect 1 nvme_errlog_growth.json "新錯誤" "num_err_log_entries 相對 baseline 成長判定 FAIL"
expect 1 nvme_hot.json           "溫度"  "溫度超過 70C 判定 FAIL"

echo "-------------------------------"
printf "通過 %d / 失敗 %d\n" "$pass" "$fail"
[ "$fail" -eq 0 ]
