#!/bin/bash
# =========================================================================
# Verdict Engine (Fail-Closed 裁決)
# 負責讀取 policy 規則，比對 baseline 與 final 的 SMART JSON。
# =========================================================================
set -u

if [ "$#" -ne 3 ]; then
  echo '{"overall_pass": false, "reasons": ["VERDICT_ARGS_ERROR"]}'
  exit 2
fi

BASE_JSON=$1
FINAL_JSON=$2
POLICY_FILE=$3

if [ ! -f "$BASE_JSON" ] || [ ! -f "$FINAL_JSON" ] || [ ! -f "$POLICY_FILE" ]; then
  echo '{"overall_pass": false, "reasons": ["EVIDENCE_MISSING"]}'
  exit 2
fi

# 輸入檔必須是合法 JSON，且 policy 必須真的含有規則。
# 舊版沒有這層檢查：policy 損毀時 num_rules 為空字串，`for (( i=0; i<; i++ ))`
# 直接算術錯誤、迴圈一次都不跑，OVERALL_PASS 維持 true —— 壞掉的 policy
# 會讓每一顆碟都拿到 PASS。
for f in "$BASE_JSON" "$FINAL_JSON"; do
  if ! jq -e . "$f" >/dev/null 2>&1; then
    echo '{"overall_pass": false, "reasons": ["EVIDENCE_UNPARSEABLE"]}'
    exit 2
  fi
done
if ! jq -e '.verdict_rules | type == "array"' "$POLICY_FILE" >/dev/null 2>&1; then
  echo '{"overall_pass": false, "reasons": ["POLICY_UNPARSEABLE_OR_MISSING_RULES"]}'
  exit 2
fi
if [ "$(jq '.verdict_rules | length' "$POLICY_FILE")" -eq 0 ]; then
  echo '{"overall_pass": false, "reasons": ["POLICY_HAS_NO_VERDICT_RULES"]}'
  exit 2
fi

OVERALL_PASS=true
REASONS=()

# Extract temperatures and smartctl RC just for logging
BASE_TEMP=$(jq -r '.temperature.current // "N/A"' "$BASE_JSON" 2>/dev/null)
FINAL_TEMP=$(jq -r '.temperature.current // "N/A"' "$FINAL_JSON" 2>/dev/null)
SMARTCTL_RC=$(jq -r '.smartctl.exit_status // 0' "$FINAL_JSON" 2>/dev/null)

# Iterate over rules in policy
num_rules=$(jq '.verdict_rules | length' "$POLICY_FILE")
for (( i=0; i<$num_rules; i++ )); do
    rule=$(jq -c ".verdict_rules[$i]" "$POLICY_FILE")
    rule_name=$(jq -r '.name' <<< "$rule")
    jq_path=$(jq -r '.jq_path' <<< "$rule")
    check_type=$(jq -r '.check' <<< "$rule")
    # 用 -c 而非 `-r '.expected // empty'`：後者會把 false 與 0 吞成空字串，
    # 缺漏時得到字面 "null"，交由下方 Fail-Closed 驗證處理。
    expected=$(jq -c '.expected' <<< "$rule")
    on_missing=$(jq -r '.on_missing // "FAIL"' <<< "$rule")
    fail_reason=$(jq -r '.fail_reason // empty' <<< "$rule")
    
    [ -z "$fail_reason" ] && fail_reason="[$rule_name 檢查失敗]"

    # --- 規則結構驗證 (Fail-Closed) ---
    # 一套自稱 Fail-Closed 的引擎，遇到寫壞的規則必須判 FAIL 而不是靜默放行。
    case "$check_type" in
        equals|max|min)
            if [ "$expected" == "null" ]; then
                OVERALL_PASS=false
                REASONS+=("[$rule_name 規則缺少 expected，policy 有誤]")
                continue
            fi
            ;;
        no_growth) ;;
        *)
            OVERALL_PASS=false
            REASONS+=("[$rule_name 未知的 check 類型: $check_type]")
            continue
            ;;
    esac
    if [ -z "$jq_path" ] || [ "$jq_path" == "null" ]; then
        OVERALL_PASS=false
        REASONS+=("[$rule_name 規則缺少 jq_path，policy 有誤]")
        continue
    fi

    # Get values using the jq_path
    # we use jq -c to avoid multiline string issues, and suppress errors if path doesn't exist
    base_val=$(jq -c "$jq_path" "$BASE_JSON" 2>/dev/null)
    final_val=$(jq -c "$jq_path" "$FINAL_JSON" 2>/dev/null)
    
    # Handle missing values
    if [ -z "$final_val" ] || [ "$final_val" == "null" ]; then
        if [ "$on_missing" == "FAIL" ]; then
            OVERALL_PASS=false
            REASONS+=("[$rule_name 缺數據]")
        fi
        continue
    fi
    
    # 比較若因型別不符等原因失敗，視為無法判定 -> Fail-Closed。
    # 注意：呼叫端一律用 `x=$(jq_cmp ...) || cmp_failed=true`。
    # 不可讓 jq_cmp 自己設旗標 —— 它在命令替換的子 shell 裡執行，賦值會隨
    # 子 shell 一起消失，錯誤將被靜默吞掉。這裡靠返回碼跨越 subshell 邊界。
    cmp_failed=false
    jq_cmp() {
        local out
        out=$(jq -n "$@" 2>/dev/null) || return 1
        [ -n "$out" ] || return 1
        printf '%s' "$out"
    }

    case "$check_type" in
        equals)
            # 嚴格 JSON 比較。舊版用 `--arg e` + tostring，expected 為 false
            # 時會退化成與空字串比對而永遠 FAIL。
            is_equal=$(jq_cmp --argjson f "$final_val" --argjson e "$expected" \
                       'if $f == $e then true else false end') || cmp_failed=true
            if [ "$cmp_failed" == "true" ]; then
                OVERALL_PASS=false
                REASONS+=("[$rule_name 無法比較 (型別不符或非數值)]")
            elif [ "$is_equal" != "true" ]; then
                OVERALL_PASS=false
                REASONS+=("$fail_reason")
            fi
            ;;
        no_growth)
            if [ -z "$base_val" ] || [ "$base_val" == "null" ]; then
                if [ "$on_missing" == "FAIL" ]; then
                     OVERALL_PASS=false
                     REASONS+=("[$rule_name 缺基準數據]")
                fi
                continue
            fi
            growth=$(jq_cmp --argjson f "$final_val" --argjson b "$base_val" \
                     'if ($f|type) != "number" or ($b|type) != "number" then error("NOT_NUMERIC") else ($f > $b) end') || cmp_failed=true
            if [ "$cmp_failed" == "true" ]; then
                OVERALL_PASS=false
                REASONS+=("[$rule_name 無法比較 (型別不符或非數值)]")
            elif [ "$growth" == "true" ]; then
                OVERALL_PASS=false
                REASONS+=("$fail_reason")
            fi
            ;;
        max)
            exceeded=$(jq_cmp --argjson f "$final_val" --argjson e "$expected" \
                       'if ($f|type) != "number" or ($e|type) != "number" then error("NOT_NUMERIC") else ($f > $e) end') || cmp_failed=true
            if [ "$cmp_failed" == "true" ]; then
                OVERALL_PASS=false
                REASONS+=("[$rule_name 無法比較 (型別不符或非數值)]")
            elif [ "$exceeded" == "true" ]; then
                OVERALL_PASS=false
                REASONS+=("$fail_reason")
            fi
            ;;
        min)
            below=$(jq_cmp --argjson f "$final_val" --argjson e "$expected" \
                    'if ($f|type) != "number" or ($e|type) != "number" then error("NOT_NUMERIC") else ($f < $e) end') || cmp_failed=true
            if [ "$cmp_failed" == "true" ]; then
                OVERALL_PASS=false
                REASONS+=("[$rule_name 無法比較 (型別不符或非數值)]")
            elif [ "$below" == "true" ]; then
                OVERALL_PASS=false
                REASONS+=("$fail_reason")
            fi
            ;;
    esac
done

# 注意：空陣列不可直接餵給 printf，`printf '%s\n'` 無參數時仍會印出一個空行，
# 導致 reasons 變成 [""] 而非 []。必須先判斷長度。
if [ "${#REASONS[@]}" -eq 0 ]; then
    reasons_json="[]"
else
    reasons_json=$(printf '%s\n' "${REASONS[@]}" | jq -R . | jq -s .)
fi

jq -n \
  --argjson pass "$OVERALL_PASS" \
  --argjson reasons "$reasons_json" \
  --arg bt "$BASE_TEMP" \
  --arg ft "$FINAL_TEMP" \
  --argjson rc "$SMARTCTL_RC" \
  '{
    overall_pass: $pass,
    reasons: $reasons,
    baseline_temp: $bt,
    final_temp: $ft,
    smartctl_rc: $rc
  }'

if [ "$OVERALL_PASS" == "true" ]; then
    exit 0
else
    exit 1
fi
