#!/bin/bash
set -um

if [ "$#" -ne 2 ]; then
  echo "Usage: crucible_controller.sh <manifest_json> <log_dir>"
  exit 2
fi

MANIFEST=$1
LOG_DIR=$2

if [ ! -f "$MANIFEST" ]; then
    echo "Manifest not found: $MANIFEST"
    exit 2
fi

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
declare -A RUNNER_PIDS

cleanup_and_abort() {
    echo "CRUCIBLE CONTROLLER: Received Abort Signal. Terminating all tasks..."
    for pgid in "${RUNNER_PIDS[@]}"; do
        if kill -0 "-$pgid" 2>/dev/null; then
            kill -TERM "-$pgid"
        fi
    done
    exit 2
}

trap cleanup_and_abort INT TERM

# Dispatch runners
num_devs=$(jq '.devices | length' "$MANIFEST")
for (( i=0; i<$num_devs; i++ )); do
    dev_obj=$(jq -c ".devices[$i]" "$MANIFEST")
    dev=$(jq -r '.device' <<< "$dev_obj")
    serial=$(jq -r '.serial' <<< "$dev_obj")
    protocol=$(jq -r '.protocol' <<< "$dev_obj")
    decision=$(jq -r '.decision' <<< "$dev_obj")
    policy_path=$(jq -r '.policy_path' <<< "$dev_obj")
    
    if [ "$decision" == "ALLOW" ]; then
        setsid "$SCRIPT_DIR/device_runner.sh" "$serial" "$dev" "$protocol" "$policy_path" "$LOG_DIR" &
        pid=$!
        pgid=$(ps -o pgid= -p "$pid" | grep -o '[0-9]*')
        RUNNER_PIDS["$serial"]=$pgid
        echo "Started runner for $dev ($serial) with PGID $pgid"
    else
        echo "Skipping $dev ($serial) - Decision: $decision"
    fi
done

if [ ${#RUNNER_PIDS[@]} -eq 0 ]; then
    echo "No allowed devices to test."
    exit 0
fi

# Wait loop
final_rc=0
for serial in "${!RUNNER_PIDS[@]}"; do
    wait "${RUNNER_PIDS[$serial]}"
    rc=$?
    if [ $rc -ne 0 ]; then
        final_rc=1
        [ $rc -eq 2 ] && final_rc=2 # Infra abort propagates
    fi
done

exit $final_rc
