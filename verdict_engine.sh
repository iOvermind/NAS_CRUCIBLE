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
    expected=$(jq -r '.expected // empty' <<< "$rule")
    on_missing=$(jq -r '.on_missing // "FAIL"' <<< "$rule")
    fail_reason=$(jq -r '.fail_reason // empty' <<< "$rule")
    
    [ -z "$fail_reason" ] && fail_reason="[$rule_name 檢查失敗]"

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
    
    case "$check_type" in
        equals)
            # Both strings or both booleans/numbers can be compared directly if they are simple values
            # Using jq to do the strict equals comparison
            is_equal=$(jq -n --argjson f "$final_val" --arg e "$expected" 'if ($f | tostring) == $e then true else false end')
            if [ "$is_equal" != "true" ]; then
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
            # check if final > base
            growth=$(jq -n --argjson f "$final_val" --argjson b "$base_val" 'if $f > $b then true else false end' 2>/dev/null)
            if [ "$growth" == "true" ]; then
                OVERALL_PASS=false
                REASONS+=("$fail_reason")
            fi
            ;;
        max)
            exceeded=$(jq -n --argjson f "$final_val" --argjson e "$expected" 'if $f > $e then true else false end' 2>/dev/null)
            if [ "$exceeded" == "true" ]; then
                OVERALL_PASS=false
                REASONS+=("$fail_reason")
            fi
            ;;
    esac
done

reasons_json=$(printf '%s\n' "${REASONS[@]}" | jq -R . | jq -s .)
[ "$reasons_json" == "[]" ] && reasons_json="[]"

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
