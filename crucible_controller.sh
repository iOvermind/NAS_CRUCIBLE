#!/bin/bash
# =========================================================================
# Layer 1: Orchestration (PGID 隔離與 Global Abort)
#
# 為什麼不用 setsid：
#   `set -m` 已經讓每個背景工作進入自己的 process group (pgid == pid)，
#   終端機的 Ctrl+C 只會送到前景 group (本腳本)，不會直接打到 runner，
#   隔離目的已達成。若再套一層 setsid，setsid 會因為呼叫者已是 group leader
#   而 fork 出子行程後立刻結束，導致：
#     1. $! 指向瞬間消失的 wrapper，wait 立即返回，測試其實還在跑；
#     2. `ps -o pgid= -p $!` 常常抓不到東西 (wrapper 已死) 而得到空字串，
#        RUNNER_PGIDS 存入空值，Global Abort 的 kill 直接失敗 —— badblocks
#        會在 Ctrl+C 之後繼續對硬碟寫入。
#   這是實測過的行為，不要把 setsid 加回來。
# =========================================================================
set -um

if [ "$#" -ne 2 ]; then
  echo "Usage: crucible_controller.sh <manifest_json> <log_dir>" >&2
  exit 2
fi

MANIFEST=$1
LOG_DIR=$2

if [ "$EUID" -ne 0 ]; then
    echo "CONTROLLER: 必須以 root 身分執行" >&2
    exit 2
fi

for cmd in jq ps kill; do
    command -v "$cmd" >/dev/null 2>&1 || { echo "CONTROLLER: 缺少必要指令: $cmd" >&2; exit 2; }
done

if [ ! -f "$MANIFEST" ]; then
    echo "CONTROLLER: Manifest not found: $MANIFEST" >&2
    exit 2
fi
if ! jq -e '(.devices | type == "array")' "$MANIFEST" >/dev/null 2>&1; then
    echo "CONTROLLER: Manifest 格式非法或缺少 .devices 陣列: $MANIFEST" >&2
    exit 2
fi
if [ ! -d "$LOG_DIR" ]; then
    echo "CONTROLLER: Log dir not found: $LOG_DIR" >&2
    exit 2
fi

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
[ -x "$SCRIPT_DIR/device_runner.sh" ] || { echo "CONTROLLER: device_runner.sh 不存在或不可執行" >&2; exit 2; }

# 以「裝置名稱」為鍵：serial 可能是 UNKNOWN 或在廉價橋接器上重複，
# 用 serial 當鍵會讓兩台裝置疊在同一個 entry，導致其中一個永遠不被 wait、
# 也不會被 Global Abort 殺掉。
declare -A RUNNER_PIDS    # dev -> pid  (供 wait)
declare -A RUNNER_PGIDS   # dev -> pgid (供 kill 整個 group)
declare -A RUNNER_SERIALS # dev -> serial (供訊息輸出)

# final_rc 語意：0=全部通過, 1=有測試失敗, 2=基礎設施中止。
# 2 具吸收性，一旦出現就不得被後續的 1 蓋掉。
final_rc=0
merge_rc() {
    case "$1" in
        0) ;;
        1) [ "$final_rc" -eq 0 ] && final_rc=1 ;;
        *) final_rc=2 ;;
    esac
}

cleanup_and_abort() {
    trap - INT TERM
    echo "CRUCIBLE CONTROLLER: Received Abort Signal. Terminating all tasks..." >&2
    for dev in "${!RUNNER_PGIDS[@]}"; do
        local pgid=${RUNNER_PGIDS[$dev]}
        [ -n "$pgid" ] || continue
        if kill -0 "-$pgid" 2>/dev/null; then
            kill -TERM "-$pgid" 2>/dev/null
        fi
    done
    # 給 runner 時間寫完 INTERRUPTED evidence，再確認是否真的收屍。
    for _ in 1 2 3 4 5 6 7 8 9 10; do
        local alive=0
        for dev in "${!RUNNER_PGIDS[@]}"; do
            local pgid=${RUNNER_PGIDS[$dev]}
            [ -n "$pgid" ] && kill -0 "-$pgid" 2>/dev/null && alive=1
        done
        [ "$alive" -eq 0 ] && break
        sleep 1
    done
    for dev in "${!RUNNER_PGIDS[@]}"; do
        local pgid=${RUNNER_PGIDS[$dev]}
        [ -n "$pgid" ] && kill -0 "-$pgid" 2>/dev/null && kill -KILL "-$pgid" 2>/dev/null
    done
    exit 2
}
trap cleanup_and_abort INT TERM

# --- Dispatch ---
any_denied=false
num_devs=$(jq '.devices | length' "$MANIFEST")
for (( i=0; i<num_devs; i++ )); do
    dev_obj=$(jq -c ".devices[$i]" "$MANIFEST")
    dev=$(jq -r '.device' <<< "$dev_obj")
    serial=$(jq -r '.serial' <<< "$dev_obj")
    protocol=$(jq -r '.protocol' <<< "$dev_obj")
    decision=$(jq -r '.decision' <<< "$dev_obj")
    policy_path=$(jq -r '.policy_path' <<< "$dev_obj")

    if [ "$decision" != "ALLOW" ]; then
        echo "Skipping $dev ($serial) - Decision: $decision"
        any_denied=true
        continue
    fi

    if [ -n "${RUNNER_PIDS[$dev]:-}" ]; then
        echo "CONTROLLER: manifest 中出現重複裝置 $dev，拒絕重複派發" >&2
        any_denied=true
        continue
    fi

    "$SCRIPT_DIR/device_runner.sh" "$serial" "$dev" "$protocol" "$policy_path" "$LOG_DIR" &
    pid=$!
    pgid=$(ps -o pgid= -p "$pid" 2>/dev/null | tr -d ' ')

    # set -m 之下 pgid 必定等於 pid。若不成立代表 job control 沒生效，
    # 此時 Global Abort 無法保證能殺乾淨 —— Fail-Closed，立刻收工。
    if [ -z "$pgid" ] || [ "$pgid" != "$pid" ]; then
        echo "CONTROLLER: 無法取得 $dev 的獨立 process group (pid=$pid pgid=${pgid:-空})" >&2
        echo "CONTROLLER: Global Abort 無法保證，中止全部測試" >&2
        kill -TERM "$pid" 2>/dev/null
        cleanup_and_abort
    fi

    RUNNER_PIDS[$dev]=$pid
    RUNNER_PGIDS[$dev]=$pgid
    RUNNER_SERIALS[$dev]=$serial
    echo "Started runner for $dev ($serial) with PGID $pgid"
done

if [ "${#RUNNER_PIDS[@]}" -eq 0 ]; then
    echo "No allowed devices to test."
    # 什麼都沒測不是成功。CI/cron 檢查 $? 時必須看得出來。
    [ "$any_denied" = true ] && exit 1
    exit 2
fi

# --- Wait ---
for dev in "${!RUNNER_PIDS[@]}"; do
    wait "${RUNNER_PIDS[$dev]}"
    rc=$?
    merge_rc "$rc"
    [ "$rc" -ne 0 ] && echo "Runner $dev (${RUNNER_SERIALS[$dev]}) exited rc=$rc" >&2
done

# 有裝置被拒絕受檢，整體不得回報成功。
[ "$any_denied" = true ] && merge_rc 1

exit "$final_rc"
