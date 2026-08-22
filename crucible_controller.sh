#!/bin/bash
set -u

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
MANIFEST_FILE="${MANIFEST_FILE:-$SCRIPT_DIR/device_manifest.json}"
DECISIONS_FILE="${DECISIONS_FILE:-$SCRIPT_DIR/policy_decisions.json}"
LOG_DIR="$SCRIPT_DIR/logs"

if [ "$EUID" -ne 0 ]; then echo "FATAL: root required" >&2; exit 2; fi
for cmd in smartctl jq lsblk findmnt zpool setsid ps readlink awk grep badblocks; do
  command -v "$cmd" >/dev/null 2>&1 || { echo "FATAL: missing dependency $cmd" >&2; exit 2; }
done
[ -x "$SCRIPT_DIR/hdd_runner.sh" ] || { echo "FATAL: hdd_runner.sh not executable" >&2; exit 2; }
[ -f "$MANIFEST_FILE" ] && jq empty "$MANIFEST_FILE" >/dev/null 2>&1 || { echo "FATAL: invalid manifest" >&2; exit 2; }
[ -f "$DECISIONS_FILE" ] && jq empty "$DECISIONS_FILE" >/dev/null 2>&1 || { echo "FATAL: invalid decisions" >&2; exit 2; }
mkdir -p "$LOG_DIR"
[ -f "$LOG_DIR/admission_denials.json" ] || printf '{}\n' > "$LOG_DIR/admission_denials.json"

set -m
declare -A ACTIVE_PIDS ACTIVE_PGIDS ACTIVE_SN
GLOBAL_ABORT=false
CONTROLLER_RC=0
ANY_LOCAL_FAILURE=false
ANY_ADMISSION_DENIED=false

record_admission_denied() {
  local sn=$1 reason=$2 expected=$3 actual=$4
  jq --arg sn "$sn" --arg reason "$reason" --arg exp "$expected" --arg act "$actual" \
    '. + {($sn): {admission:{decision:"DENIED",reason:$reason,expected:$exp,actual:$act}}}' \
    "$LOG_DIR/admission_denials.json" > "$LOG_DIR/admission_denials.json.tmp" && mv "$LOG_DIR/admission_denials.json.tmp" "$LOG_DIR/admission_denials.json"
  ANY_ADMISSION_DENIED=true
}

trigger_global_abort() {
  local rc=$1
  [ "$GLOBAL_ABORT" = true ] && return 0
  GLOBAL_ABORT=true
  CONTROLLER_RC=$rc
  for pid in "${!ACTIVE_PGIDS[@]}"; do
    local pgid="${ACTIVE_PGIDS[$pid]}"
    [ -n "$pgid" ] && kill -TERM -- "-$pgid" 2>/dev/null || true
  done
}
trap 'trigger_global_abort 130' INT
trap 'trigger_global_abort 143' TERM

while IFS= read -r sn; do
  [ -n "$sn" ] || continue
  dev=$(jq -r --arg sn "$sn" '.[$sn].identity.device_handle // empty' "$MANIFEST_FILE")
  protocol=$(jq -r --arg sn "$sn" '.[$sn].identity.protocol // empty' "$MANIFEST_FILE")
  dec=$(jq -c --arg sn "$sn" '.[$sn] // empty' "$DECISIONS_FILE")
  decision=$(jq -r '.decision // "BLOCK"' <<<"$dec")
  profile=$(jq -r '.policy.execution_profile // "NONE"' <<<"$dec")
  pol_name=$(jq -r '.policy.name // "UNKNOWN"' <<<"$dec")
  pol_ver=$(jq -r '.policy.version // "UNKNOWN"' <<<"$dec")

  [ -n "$dev" ] || { record_admission_denied "$sn" MISSING_DEVICE_HANDLE NONEMPTY EMPTY; continue; }
  [[ "$protocol" == ATA || "$protocol" == SCSI ]] || { record_admission_denied "$sn" UNSUPPORTED_PROTOCOL ATA_OR_SCSI "${protocol:-EMPTY}"; continue; }
  if [ "$decision" != ALLOW ]; then
    record_admission_denied "$sn" "POLICY_${decision}" ALLOW "$decision"
    continue
  fi
  if [ "$profile" != HDD_FULL_BURNIN ]; then
    record_admission_denied "$sn" EXECUTION_PROFILE_MISMATCH HDD_FULL_BURNIN "$profile"
    continue
  fi

  BADBLOCKS_TIMEOUT=${BADBLOCKS_TIMEOUT:-302400}
  SMART_LONG_TIMEOUT=${SMART_LONG_TIMEOUT:-86400}
  export LOG_DIR BADBLOCKS_TIMEOUT SMART_LONG_TIMEOUT
  setsid "$SCRIPT_DIR/hdd_runner.sh" "$sn" "$dev" "$profile" "$pol_name" "$pol_ver" "$protocol" &
  pid=$!
  pgid=$(ps -o pgid= -p "$pid" | tr -d ' ')
  [ -n "$pgid" ] || pgid=$pid
  ACTIVE_PIDS["$pid"]="$sn"
  ACTIVE_PGIDS["$pid"]="$pgid"
  ACTIVE_SN["$pid"]="$sn"
done < <(jq -r 'keys[]' "$MANIFEST_FILE")

while [ ${#ACTIVE_PIDS[@]} -gt 0 ]; do
  wait -n 2>/dev/null || true
  for pid in "${!ACTIVE_PIDS[@]}"; do
    if ! kill -0 "$pid" 2>/dev/null; then
      sn="${ACTIVE_SN[$pid]}"
      wait "$pid" 2>/dev/null; rc=$?
      unset 'ACTIVE_PIDS[$pid]' 'ACTIVE_PGIDS[$pid]' 'ACTIVE_SN[$pid]'
      case "$rc" in
        0) ;;
        1) ANY_LOCAL_FAILURE=true ;;
        2|130|143) trigger_global_abort "$rc" ;;
        *) ANY_LOCAL_FAILURE=true ;;
      esac
      echo "Runner $sn exited rc=$rc"
    fi
  done
done

if [ "$GLOBAL_ABORT" = true ]; then exit "$CONTROLLER_RC"; fi
if [ "$ANY_LOCAL_FAILURE" = true ]; then exit 1; fi
if [ "$ANY_ADMISSION_DENIED" = true ]; then exit 1; fi
exit 0
