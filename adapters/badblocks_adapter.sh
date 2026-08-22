#!/bin/bash
# =========================================================================
# M2A-3A: Badblocks Adapter (Host-driven PGID 隔離邊界)
# =========================================================================
_bb_is_device_accessible() {
    local dev=$1
    [ -b "/dev/$dev" ] || return 1
    [ -e "/sys/class/block/$dev/device" ] || return 1
    smartctl -i "/dev/$dev" >/dev/null 2>&1 || return 1
    return 0 
}

badblocks_adapter() {
    local dev=$1 serial=$2 log_dir=$3 timeout_sec=${4:-302400}
    local log_file="$log_dir/${serial}_badblocks.log"
    local ev_file="$log_dir/${serial}_badblocks_evidence.json"
    
    local final_rc=2 reason="UNCLASSIFIED_FAILURE"
    local child_pid=0 child_pgid=0 abort_signal="" timeout_triggered="false" raw_rc=0

    trap 'abort_signal=130; [ -n "$child_pgid" ] && kill -TERM -- "-$child_pgid" 2>/dev/null' INT
    trap 'abort_signal=143; [ -n "$child_pgid" ] && kill -TERM -- "-$child_pgid" 2>/dev/null' TERM

    set -m
    setsid bash -c '"$@"' _ badblocks -wsv -b 4096 "/dev/$dev" > "$log_file" 2>&1 &
    child_pid=$!
    child_pgid=$child_pid
    
    local elapsed=0
    while true; do
        if [ -n "$abort_signal" ]; then wait "$child_pid" 2>/dev/null; break; fi
        if ! kill -0 "$child_pid" 2>/dev/null; then wait "$child_pid" 2>/dev/null; raw_rc=$?; break; fi
        if [ "$elapsed" -ge "$timeout_sec" ]; then
            timeout_triggered="true"
            kill -TERM -- "-$child_pgid" 2>/dev/null
            wait "$child_pid" 2>/dev/null; raw_rc=$?
            break
        fi
        sleep 1
        elapsed=$((elapsed+1))
    done

    trap - INT TERM
    set +m

    if [ -n "$abort_signal" ]; then final_rc=$abort_signal; reason="INTERRUPTED_BY_SIGNAL"
    elif [ "$timeout_triggered" == "true" ]; then final_rc=2; reason="WORKLOAD_TIMEOUT_OR_ENVIRONMENT_FAILURE"
    elif [ "$raw_rc" -eq 0 ]; then final_rc=0; reason="WORKLOAD_COMPLETED"
    elif [ "$raw_rc" -eq 1 ]; then
        if ! _bb_is_device_accessible "$dev"; then final_rc=2; reason="INFRASTRUCTURE_DEVICE_LOST_OR_TRANSPORT_BROKEN"
        else final_rc=1; reason="WORKLOAD_FAILED"; fi
    else
        final_rc=2
        [ "$raw_rc" -eq 127 ] && reason="EXECUTOR_NOT_FOUND" || reason="INFRASTRUCTURE_OR_UNCLASSIFIED_FAILURE"
    fi

    local ev_status="UNKNOWN"
    case $final_rc in
        0) ev_status="COMPLETED" ;; 1) ev_status="FAILED" ;;
        2) ev_status="ABORTED" ;; 130|143) ev_status="INTERRUPTED" ;;
    esac

    if ! jq -n \
       --arg rc "$final_rc" --arg rsn "$reason" --arg stat "$ev_status" \
       --argjson pid "$child_pid" --argjson pgid "$child_pgid" \
       '{
         adapter: {name: "badblocks", version: "1.0"},
         process: {pid: $pid, pgid: $pgid},
         execution: {status: $stat, exit_code: ($rc | tonumber), reason: $rsn}
       }' > "$ev_file" 2>/dev/null; then
        echo "❌ [badblocks_adapter] Evidence write failed: $ev_file" >&2
        return 2
    fi
    return "$final_rc"
}
