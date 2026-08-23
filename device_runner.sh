#!/bin/bash
set -u

if [ "$#" -ne 5 ]; then
  echo "INVALID_RUNNER_ARGUMENTS: expected 5, got $#" >&2
  exit 2
fi

SERIAL=$1
DEV=$2
PROTOCOL=$3
POLICY_FILE=$4
LOG_DIR=$5

[ "$EUID" -eq 0 ] || exit 2
command -v jq >/dev/null 2>&1 || exit 2
command -v smartctl >/dev/null 2>&1 || exit 2
case "$PROTOCOL" in ATA|SCSI|NVMe) ;; *) exit 2;; esac
# NVMe 走 nvme-cli 執行 device self-test，缺工具直接 Fail-Closed
[ "$PROTOCOL" != "NVMe" ] || command -v nvme >/dev/null 2>&1 || exit 2
[ -f "$POLICY_FILE" ] || exit 2

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
EXEC_FILE="$LOG_DIR/exec_record_${SERIAL}.json"
mkdir -p "$LOG_DIR"

source "$SCRIPT_DIR/adapters/precheck_adapter.sh"
source "$SCRIPT_DIR/adapters/snapshot_adapter.sh"
source "$SCRIPT_DIR/adapters/smartctl_long_adapter.sh"
source "$SCRIPT_DIR/adapters/nvme_smart_long_adapter.sh"
source "$SCRIPT_DIR/adapters/badblocks_adapter.sh"
source "$SCRIPT_DIR/lib/device_probe.sh"

POL_NAME=$(jq -r '.name' "$POLICY_FILE")
POL_VER=$(jq -r '.version' "$POLICY_FILE")
PROFILE=$(jq -r '.execution_profile' "$POLICY_FILE")

PHASES=(precheck baseline_snapshot smart_long_1 badblocks smart_long_2 final_snapshot verdict)

jq -n --arg sn "$SERIAL" --arg prof "$PROFILE" --arg pn "$POL_NAME" --arg pv "$POL_VER" \
  '{serial:$sn,execution:{profile:$prof,policy:{name:$pn,version:$pv},status:"STARTING",current_phase:"none",phases:{}}}' > "$EXEC_FILE"
for p in "${PHASES[@]}"; do jq --arg p "$p" '.execution.phases[$p]={status:"PENDING"}' "$EXEC_FILE" > "$EXEC_FILE.tmp" && mv "$EXEC_FILE.tmp" "$EXEC_FILE"; done

update_exec_status() {
  jq --arg st "$1" '.execution.status=$st' "$EXEC_FILE" > "$EXEC_FILE.tmp" && mv "$EXEC_FILE.tmp" "$EXEC_FILE"
}

update_phase_state() {
  local p=$1 new_st=$2 ec=${3:-0} rsn=${4:-}
  local curr_st
  curr_st=$(jq -r --arg p "$p" '.execution.phases[$p].status // "PHASE_NOT_FOUND"' "$EXEC_FILE")
  [ "$curr_st" != "PHASE_NOT_FOUND" ] || { update_exec_status ABORTED; exit 2; }
  local valid=false
  if [ "$curr_st" = PENDING ] && [[ "$new_st" =~ ^(RUNNING|SKIPPED)$ ]]; then valid=true; fi
  if [ "$curr_st" = RUNNING ] && [[ "$new_st" =~ ^(PASS|FAIL|ABORTED|INTERRUPTED)$ ]]; then valid=true; fi
  [ "$valid" = true ] || { update_exec_status ABORTED; exit 2; }
  if [ "$new_st" = RUNNING ]; then
    jq --arg p "$p" '.execution.current_phase=$p | .execution.phases[$p].status="RUNNING"' "$EXEC_FILE" > "$EXEC_FILE.tmp" && mv "$EXEC_FILE.tmp" "$EXEC_FILE"
  else
    jq --arg p "$p" --arg st "$new_st" --argjson ec "$ec" --arg rsn "$rsn" \
      '.execution.phases[$p]={status:$st,exit_code:$ec,reason:$rsn}' "$EXEC_FILE" > "$EXEC_FILE.tmp" && mv "$EXEC_FILE.tmp" "$EXEC_FILE"
  fi
}

handle_interrupt() {
  local sig=$1 curr_phase
  curr_phase=$(jq -r '.execution.current_phase // "none"' "$EXEC_FILE" 2>/dev/null || echo none)
  if [ "$curr_phase" != none ] && [ "$curr_phase" != null ]; then
    update_phase_state "$curr_phase" INTERRUPTED "$sig" "GLOBAL_ABORT_INFRASTRUCTURE_FAILURE"
  fi
  for p in "${PHASES[@]}"; do
    local st
    st=$(jq -r --arg p "$p" '.execution.phases[$p].status // "UNKNOWN"' "$EXEC_FILE" 2>/dev/null || echo UNKNOWN)
    [ "$st" = PENDING ] && update_phase_state "$p" SKIPPED 0 CASCADED_FROM_GLOBAL_ABORT
  done
  jq '.execution.status="INTERRUPTED" | .execution.current_phase="none"' "$EXEC_FILE" > "$EXEC_FILE.tmp" && mv "$EXEC_FILE.tmp" "$EXEC_FILE"
  exit "$sig"
}
trap 'handle_interrupt 130' INT
trap 'handle_interrupt 143' TERM

validate_evidence() {
  local ev=$1 expected_rc=$2
  [ -f "$ev" ] || return 1
  jq -e '
    .execution and
    (.execution.status|type=="string") and
    (.execution.exit_code|type=="number") and
    (.execution.reason|type=="string")
  ' "$ev" >/dev/null 2>&1 || return 1
  local ev_rc; ev_rc=$(jq -r '.execution.exit_code' "$ev")
  [ "$ev_rc" = "$expected_rc" ] || return 1
}

run_phase() {
  # 必須分開宣告。`local a=$1 b="${a}"` 在 set -u 之下會失敗：bash 會先把
  # 同一個 local 陳述句裡的所有名稱都宣告成 local (未設值)，才依序賦值，
  # 因此第三個詞展開到的是「未綁定的 local phase」而非參數值。
  # 舊版寫成一行，run_phase 在第一個 phase 就以「未綁定的變數」中止，
  # 整個執行層從未真正跑完任何一次 burn-in。
  local phase=$1
  local rc=2
  local ev_file="$LOG_DIR/${SERIAL}_${phase}_evidence.json"
  
  # Check if policy disables this phase
  # policy 用 "smart_long" 一個區段涵蓋兩輪，但 phase 叫 smart_long_1/_2，
  # 拿 phase 當 key 查不到任何東西。
  local policy_section=$phase
  case "$phase" in
    smart_long_1|smart_long_2) policy_section="smart_long" ;;
  esac
  # 不可寫成 `.enabled // true`：jq 只把 null 與 false 視為假值，所以
  # `// true` 會把 `"enabled": false` 也一併換成 true —— 這個 phase 將
  # 永遠無法被 policy 停用，24 小時的長測照跑不誤。缺鍵才套預設值。
  local enabled
  enabled=$(jq -r ".phases.\"$policy_section\".enabled" "$POLICY_FILE" 2>/dev/null)
  if [ -z "$enabled" ] || [ "$enabled" == "null" ]; then
      enabled=true
  fi
  if [ "$enabled" == "false" ]; then
      update_phase_state "$phase" SKIPPED 0 "DISABLED_BY_POLICY"
      return 0
  fi

  update_phase_state "$phase" RUNNING
  rm -f "$ev_file"
  
  case "$phase" in
    precheck) precheck_adapter "$DEV" "$SERIAL" "$PROTOCOL" "$LOG_DIR"; rc=$?;;
    baseline_snapshot|final_snapshot) snapshot_adapter "$DEV" "$SERIAL" "$LOG_DIR" "$phase"; rc=$?;;
    smart_long_1|smart_long_2) 
        local timeout
        timeout=$(jq -r ".phases.smart_long.timeout // 86400" "$POLICY_FILE")  # 同 policy_section
        if [ "$PROTOCOL" = "NVMe" ]; then
            nvme_smart_long_adapter "$DEV" "$SERIAL" "$PROTOCOL" "$LOG_DIR" "$timeout" "$phase"; rc=$?
        else
            smartctl_long_adapter "$DEV" "$SERIAL" "$PROTOCOL" "$LOG_DIR" "$timeout" "$phase"; rc=$?
        fi
        ;;
    badblocks) 
        local timeout
        timeout=$(jq -r ".phases.badblocks.timeout // 302400" "$POLICY_FILE")
        badblocks_adapter "$DEV" "$SERIAL" "$LOG_DIR" "$timeout"; rc=$?
        ;;
    verdict)
        "$SCRIPT_DIR/verdict_engine.sh" "$LOG_DIR/${SERIAL}_baseline_snapshot.json" "$LOG_DIR/${SERIAL}_final_snapshot.json" "$POLICY_FILE" > "$ev_file"
        rc=$?
        if [ $rc -eq 0 ]; then
            jq -n --argjson rc $rc --argjson orig "$(<"$ev_file")" '{adapter:{name:"verdict",version:"1.0"}, execution:{status:"COMPLETED",exit_code:$rc,reason:"VERDICT_PASS"}, observation:$orig}' > "${ev_file}.tmp" && mv "${ev_file}.tmp" "$ev_file"
        elif [ $rc -eq 1 ]; then
            jq -n --argjson rc $rc --argjson orig "$(<"$ev_file")" '{adapter:{name:"verdict",version:"1.0"}, execution:{status:"FAILED",exit_code:$rc,reason:"VERDICT_FAIL"}, observation:$orig}' > "${ev_file}.tmp" && mv "${ev_file}.tmp" "$ev_file"
        else
            jq -n --argjson rc $rc '{adapter:{name:"verdict",version:"1.0"}, execution:{status:"ABORTED",exit_code:$rc,reason:"VERDICT_ENGINE_ERROR"}}' > "${ev_file}.tmp" && mv "${ev_file}.tmp" "$ev_file"
        fi
        ;;
    *) update_phase_state "$phase" ABORTED 2 UNKNOWN_PHASE; return 2;;
  esac
  
  if ! validate_evidence "$ev_file" "$rc"; then
    update_phase_state "$phase" ABORTED 2 ADAPTER_CONTRACT_VIOLATION
    return 2
  fi
  
  case "$rc" in
    0) update_phase_state "$phase" PASS 0 "$(jq -r '.execution.reason' "$ev_file")";;
    1) update_phase_state "$phase" FAIL 1 "$(jq -r '.execution.reason' "$ev_file")";;
    2) update_phase_state "$phase" ABORTED 2 "$(jq -r '.execution.reason' "$ev_file")";;
    130|143) update_phase_state "$phase" INTERRUPTED "$rc" "$(jq -r '.execution.reason' "$ev_file")";;
    *) update_phase_state "$phase" ABORTED 2 UNKNOWN_ADAPTER_EXIT; rc=2;;
  esac
  return "$rc"
}

update_exec_status RUNNING
final_rc=0
failed=false
infra_abort=false
interrupted=false

# rc 語意：0=通過, 1=工作負載失敗, 2=基礎設施中止。2 具吸收性。
merge_final_rc() {
  case "$1" in
    0) ;;
    1) [ "$final_rc" -eq 0 ] && final_rc=1 ;;
    *) final_rc=2 ;;
  esac
}

# 蒐證階段：即使工作負載失敗也必須執行。
# badblocks 回報 rc=1 (發現壞軌) 或 SMART long test 判定失敗，正是
# reallocated_sector / pending_sector 計數最關鍵的時刻；舊版在這裡把
# final_snapshot 與 verdict 一併 SKIPPED，導致 <serial>_verdict_evidence.json
# 根本不存在，crucible.sh 只印得出「FAIL [未完成]」——把最需要解釋的失敗
# 變成最沒有證據的失敗。
is_evidence_phase() {
  case "$1" in final_snapshot|verdict) return 0 ;; *) return 1 ;; esac
}

for p in "${PHASES[@]}"; do
  if [ "$failed" = true ]; then
    # 基礎設施中止 (rc=2) 代表裝置或工具已不可信，蒐證也無意義，全部跳過。
    if [ "$infra_abort" = true ] || ! is_evidence_phase "$p"; then
      update_phase_state "$p" SKIPPED 0 "PREVIOUS_PHASE_FAILED"
      continue
    fi
  fi
  run_phase "$p"; rc=$?
  if [ "$rc" -ne 0 ]; then
    failed=true
    [ "$rc" -ne 1 ] && infra_abort=true
    case "$rc" in 130|143) interrupted=true ;; esac
    merge_final_rc "$rc"
  fi
done

# merge_final_rc 已把 130/143 正規化成 2，所以中斷與否要靠旗標判斷，
# 不能再從 final_rc 反推。
if [ "$interrupted" = true ]; then
  update_exec_status INTERRUPTED
else
  case "$final_rc" in
    0) update_exec_status COMPLETED;;
    1) update_exec_status FAILED_EXECUTION;;
    *) update_exec_status ABORTED;;
  esac
fi
jq '.execution.current_phase="none"' "$EXEC_FILE" > "$EXEC_FILE.tmp" && mv "$EXEC_FILE.tmp" "$EXEC_FILE"

exit "$final_rc"
