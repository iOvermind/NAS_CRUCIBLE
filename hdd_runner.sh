#!/bin/bash
set -u

if [ "$#" -ne 6 ]; then
  echo "INVALID_RUNNER_ARGUMENTS: expected 6, got $#" >&2
  exit 2
fi

SERIAL=$1
DEV=$2
PROFILE=$3
POL_NAME=$4
POL_VER=$5
PROTOCOL=$6

[ "$EUID" -eq 0 ] || exit 2
[ "$PROFILE" = "HDD_FULL_BURNIN" ] || exit 2
command -v jq >/dev/null 2>&1 || exit 2
command -v smartctl >/dev/null 2>&1 || exit 2
case "$PROTOCOL" in ATA|SCSI) ;; *) exit 2;; esac

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
LOG_DIR="$SCRIPT_DIR/logs"
EXEC_FILE="$LOG_DIR/exec_record_${SERIAL}.json"
mkdir -p "$LOG_DIR"

source "$SCRIPT_DIR/adapters/precheck_adapter.sh"
source "$SCRIPT_DIR/adapters/snapshot_adapter.sh"
source "$SCRIPT_DIR/adapters/smartctl_long_adapter.sh"
source "$SCRIPT_DIR/adapters/badblocks_adapter.sh"

PHASES=(precheck baseline_snapshot smart_long_1 badblocks smart_long_2 final_snapshot)

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
  local phase=$1 rc=2 ev_file="$LOG_DIR/${SERIAL}_${phase}_evidence.json"
  update_phase_state "$phase" RUNNING
  rm -f "$ev_file"
  case "$phase" in
    precheck) precheck_adapter "$DEV" "$SERIAL" "$PROTOCOL" "$LOG_DIR"; rc=$?;;
    baseline_snapshot|final_snapshot) snapshot_adapter "$DEV" "$SERIAL" "$LOG_DIR" "$phase"; rc=$?;;
    smart_long_1|smart_long_2) smartctl_long_adapter "$DEV" "$SERIAL" "$PROTOCOL" "$LOG_DIR" "${SMART_LONG_TIMEOUT:-86400}"; rc=$?;;
    badblocks) badblocks_adapter "$DEV" "$SERIAL" "$LOG_DIR" "${BADBLOCKS_TIMEOUT:-302400}"; rc=$?;;
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
for p in "${PHASES[@]}"; do
  if [ "$failed" = true ]; then
    update_phase_state "$p" SKIPPED 0 PREVIOUS_PHASE_FAILED
    continue
  fi
  run_phase "$p"
  rc=$?
  if [ "$rc" -ne 0 ]; then failed=true; final_rc=$rc; fi
done

case "$final_rc" in
  0) update_exec_status COMPLETED;;
  1) update_exec_status FAILED_EXECUTION;;
  2) update_exec_status ABORTED;;
  130|143) update_exec_status INTERRUPTED;;
  *) final_rc=2; update_exec_status ABORTED;;
esac
jq '.execution.current_phase="none"' "$EXEC_FILE" > "$EXEC_FILE.tmp" && mv "$EXEC_FILE.tmp" "$EXEC_FILE"
exit "$final_rc"
