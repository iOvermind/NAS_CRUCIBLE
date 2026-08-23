#!/bin/bash
# =========================================================================
# Verdict Engine 規則契約測試 (Fail-Closed 保證)
#   一套自稱 Fail-Closed 的引擎，遇到寫壞的 policy 或無法比較的數值時
#   必須判 FAIL。這裡覆蓋的全是「舊版會靜默 PASS」的路徑。
# =========================================================================
set -u
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
ENGINE="$ROOT/verdict_engine.sh"
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT

pass=0; fail=0
snap() { jq -n --argjson t "$1" --argjson p "$2" \
    '{smart_status:{passed:$p},temperature:{current:$t},
      nvme_smart_health_information_log:{media_errors:0}}' ; }
snap 40 true > "$TMP/base.json"

# expect <desc> <期望判定 PASS|FAIL> <policy rules JSON> [final snapshot]
expect() {
    local desc=$1 want=$2 rules=$3 final=${4:-}
    [ -n "$final" ] && printf '%s' "$final" > "$TMP/final.json" || snap 40 true > "$TMP/final.json"
    local rjson; rjson=$(jq -cn "$rules")   # 規則以 jq 語法書寫，先正規化成 JSON
    jq -n --argjson r "$rjson" '{name:"T",version:"1.0",execution_profile:"X",verdict_rules:$r}' > "$TMP/pol.json"
    local out; out=$("$ENGINE" "$TMP/base.json" "$TMP/final.json" "$TMP/pol.json" 2>/dev/null)
    local got; got=$(jq -r 'if .overall_pass then "PASS" else "FAIL" end' <<<"$out" 2>/dev/null)
    if [ "$got" == "$want" ]; then
        printf "  ✅ %s\n" "$desc"; pass=$((pass+1))
    else
        printf "  ❌ %s (期望 %s, 實得 %s | %s)\n" "$desc" "$want" "${got:-無輸出}" "$(jq -c '.reasons' <<<"$out" 2>/dev/null)"
        fail=$((fail+1))
    fi
}

echo "== Verdict Engine 規則契約 =="

# --- max/min 缺 expected：舊版 --argjson e "" 讓 jq 報錯，規則靜默通過 ---
expect "max 規則缺 expected -> FAIL (不得靜默放行)" FAIL \
  '[{name:"temp_ceiling",jq_path:".temperature.current",check:"max",fail_reason:"溫度過高"}]'
expect "min 規則缺 expected -> FAIL (不得靜默放行)" FAIL \
  '[{name:"spare_floor",jq_path:".temperature.current",check:"min",fail_reason:"備援不足"}]'

# --- 未知 check 類型：舊版 case 無 default，整條規則被跳過 ---
expect "未知 check 類型 -> FAIL" FAIL \
  '[{name:"bogus",jq_path:".temperature.current",check:"betweeen",expected:5,fail_reason:"x"}]'
expect "規則缺 jq_path -> FAIL" FAIL \
  '[{name:"nopath",check:"max",expected:70,fail_reason:"x"}]'

# --- expected: false：舊版 `// empty` 吞掉 false，退化成與空字串比對 ---
expect "expected:false 且實際 false -> PASS" PASS \
  '[{name:"sp",jq_path:".smart_status.passed",check:"equals",expected:false,fail_reason:"x"}]' \
  "$(snap 40 false)"
expect "expected:false 但實際 true -> FAIL" FAIL \
  '[{name:"sp",jq_path:".smart_status.passed",check:"equals",expected:false,fail_reason:"x"}]' \
  "$(snap 40 true)"

# --- expected: 0 同樣不可被 `// empty` 吞掉 ---
expect "expected:0 且實際 0 -> PASS" PASS \
  '[{name:"me",jq_path:".nvme_smart_health_information_log.media_errors",check:"equals",expected:0,fail_reason:"x"}]'

# --- 型別不符無法比較 -> Fail-Closed ---
expect "數值規則遇到字串資料 -> FAIL" FAIL \
  '[{name:"temp",jq_path:".smart_status.passed",check:"max",expected:70,fail_reason:"x"}]'

# --- 正常路徑仍須可用 ---
# --- policy 本身損毀 -> Fail-Closed ---
echo 'not json at all' > "$TMP/broken.json"
snap 40 true > "$TMP/final.json"
out=$("$ENGINE" "$TMP/base.json" "$TMP/final.json" "$TMP/broken.json" 2>/dev/null)
if [ "$(jq -r '.overall_pass' <<<"$out" 2>/dev/null)" == "false" ]; then
    printf "  ✅ policy 損毀 -> FAIL (不得整批放行)\n"; pass=$((pass+1))
else
    printf "  ❌ policy 損毀 -> FAIL (實得 %s)\n" "${out:-無輸出}"; fail=$((fail+1))
fi
expect "policy 無任何 verdict_rules -> FAIL" FAIL '[]'

# --- 正常路徑仍須可用 ---
expect "健康碟通過所有規則 -> PASS" PASS \
  '[{name:"sp",jq_path:".smart_status.passed",check:"equals",expected:true,fail_reason:"x"},
    {name:"tc",jq_path:".temperature.current",check:"max",expected:70,fail_reason:"y"}]'

echo "-------------------------------"
printf "通過 %d / 失敗 %d\n" "$pass" "$fail"
[ "$fail" -eq 0 ]
