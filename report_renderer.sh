#!/bin/bash
# =========================================================================
# Layer 2: Summary Report 渲染器
#
# 把 logs/<ts>/ 底下的 manifest、exec_record 與 verdict evidence 彙整成人看的
# 摘要 (CSV + HTML)。Summary Report 是 Evidence 的衍生物，不是證據本身 ——
# 任何時候都能從 Evidence 重新產生，因此這支腳本必須是純函數且可重複執行。
#
# 每顆碟判定完就重跑一次 (device_runner 尾端呼叫)，這樣 3-5 天的測試中途斷電
# 時，摘要裡至少有已經跑完的那幾顆。
#
# 用法: report_renderer.sh <log_dir> [out_dir]
#       out_dir 未指定時寫回 log_dir。Live 環境下 out_dir 是 FAT32 摘要分區，
#       插到任何電腦上都讀得到。
# =========================================================================
set -u

[ "$#" -ge 1 ] || { echo "Usage: report_renderer.sh <log_dir> [out_dir]" >&2; exit 2; }
command -v jq >/dev/null 2>&1 || exit 2

LOG_DIR=$1
OUT_DIR=${2:-$1}
MANIFEST="$LOG_DIR/device_manifest.json"

[ -d "$LOG_DIR" ] || { echo "report_renderer: log dir 不存在: $LOG_DIR" >&2; exit 2; }
[ -f "$MANIFEST" ] || { echo "report_renderer: manifest 不存在: $MANIFEST" >&2; exit 2; }
mkdir -p "$OUT_DIR" 2>/dev/null || { echo "report_renderer: 無法寫入 $OUT_DIR" >&2; exit 2; }

BUILD_COMMIT="unknown"
BUILD_INFO="$LOG_DIR/build_info.json"
[ -f "$BUILD_INFO" ] && BUILD_COMMIT=$(jq -r '.commit_short // "unknown"' "$BUILD_INFO" 2>/dev/null)
GENERATED=$(date '+%Y-%m-%d %H:%M:%S %Z')
NOPERSIST_FLAG="${CRUCIBLE_NOPERSIST_FLAG:-/run/crucible/no-persistence}"

# -------------------------------------------------------------------------
# 逐碟彙整成一個 JSON 陣列，CSV 與 HTML 都從它產生 —— 兩種格式不得各算一次，
# 否則遲早會出現「CSV 說 PASS、HTML 說 FAIL」。
# -------------------------------------------------------------------------
rows="[]"
num=$(jq '.devices | length' "$MANIFEST" 2>/dev/null) || num=0
for (( i=0; i<num; i++ )); do
    d=$(jq -c ".devices[$i]" "$MANIFEST")
    dev=$(jq -r '.device'                <<<"$d")
    serial=$(jq -r '.serial'             <<<"$d")
    model=$(jq -r '.model // "UNKNOWN"'  <<<"$d")
    class=$(jq -r '.class'               <<<"$d")
    decision=$(jq -r '.decision'         <<<"$d")
    breason=$(jq -r '.block_reason // ""' <<<"$d")
    overridden=$(jq -r '.overridden // false' <<<"$d")

    exec_status="NOT_STARTED"; result="-"; reasons=""; btemp=""; ftemp=""

    if [ "$decision" = "ALLOW" ]; then
        exec_file="$LOG_DIR/exec_record_${serial}.json"
        verdict_file="$LOG_DIR/${serial}_verdict_evidence.json"
        [ -f "$exec_file" ] && exec_status=$(jq -r '.execution.status // "UNKNOWN"' "$exec_file" 2>/dev/null)

        if [ -f "$verdict_file" ]; then
            # verdict evidence 由 runner 包過一層，觀察值在 .observation 底下。
            if [ "$(jq -r '.observation.overall_pass // false' "$verdict_file" 2>/dev/null)" = "true" ]; then
                result="PASS"
            else
                result="FAIL"
            fi
            reasons=$(jq -r '(.observation.reasons // []) | join("; ")' "$verdict_file" 2>/dev/null)
            btemp=$(jq -r '.observation.baseline_temp // ""' "$verdict_file" 2>/dev/null)
            ftemp=$(jq -r '.observation.final_temp // ""'    "$verdict_file" 2>/dev/null)
        else
            # 沒有 verdict evidence 就不是 PASS。這裡絕不能因為「還沒跑完」
            # 而留白 —— 留白會被讀成沒問題。
            case "$exec_status" in
                RUNNING|STARTING) result="RUNNING" ;;
                NOT_STARTED)      result="-" ;;
                *)                result="FAIL"; reasons="未產出 verdict evidence (狀態: $exec_status)" ;;
            esac
        fi
    else
        result="BLOCKED"
        reasons="$breason"
    fi

    rows=$(jq --arg dev "$dev" --arg sn "$serial" --arg mdl "$model" --arg cls "$class" \
              --arg dec "$decision" --arg ovr "$overridden" --arg st "$exec_status" \
              --arg res "$result" --arg rsn "$reasons" --arg bt "$btemp" --arg ft "$ftemp" \
        '. + [{device:$dev, serial:$sn, model:$mdl, class:$cls, decision:$dec,
               overridden:($ovr=="true"), exec_status:$st, result:$res,
               reasons:$rsn, baseline_temp:$bt, final_temp:$ft}]' <<<"$rows")
done

# --- CSV ---------------------------------------------------------------
# 前置 BOM，Excel 才不會把 UTF-8 讀成亂碼。
{
    printf '\xef\xbb\xbf'
    echo "device,serial,model,class,result,exec_status,overridden,baseline_temp,final_temp,reasons"
    jq -r '.[] | [.device, .serial, .model, .class, .result, .exec_status,
                  (if .overridden then "YES" else "" end),
                  .baseline_temp, .final_temp, .reasons] | @csv' <<<"$rows"
} > "$OUT_DIR/summary.csv.tmp" && mv "$OUT_DIR/summary.csv.tmp" "$OUT_DIR/summary.csv"

# --- HTML --------------------------------------------------------------
total=$(jq 'length' <<<"$rows")
n_pass=$(jq '[.[] | select(.result=="PASS")]    | length' <<<"$rows")
n_fail=$(jq '[.[] | select(.result=="FAIL")]    | length' <<<"$rows")
n_block=$(jq '[.[] | select(.result=="BLOCKED")]| length' <<<"$rows")
n_run=$(jq '[.[] | select(.result=="RUNNING")]  | length' <<<"$rows")

{
cat <<HTML
<!doctype html>
<html lang="zh-Hant"><head><meta charset="utf-8">
<title>NAS_CRUCIBLE 燒機報告</title>
<style>
 body{font-family:system-ui,"Noto Sans CJK TC",sans-serif;margin:2rem;color:#111;background:#fafafa}
 h1{font-size:1.3rem;margin:0 0 .3rem}
 .meta{color:#666;font-size:.85rem;margin-bottom:1rem}
 .warn{background:#fff3cd;border:1px solid #e0b400;padding:.8rem;margin:1rem 0;border-radius:4px}
 table{border-collapse:collapse;width:100%;background:#fff;font-size:.9rem}
 th,td{border:1px solid #ddd;padding:.45rem .6rem;text-align:left;vertical-align:top}
 th{background:#f0f0f0}
 .PASS{color:#0a7a2f;font-weight:700}
 .FAIL{color:#c00;font-weight:700}
 .BLOCKED{color:#8a6d00;font-weight:700}
 .RUNNING{color:#0057b8;font-weight:700}
 .tag{background:#ffe9b3;border-radius:3px;padding:0 .3rem;font-size:.8rem}
</style></head><body>
<h1>NAS_CRUCIBLE 燒機報告</h1>
<div class="meta">產生時間 $GENERATED ｜ build $BUILD_COMMIT ｜
 合計 $total 顆：PASS $n_pass ／ FAIL $n_fail ／ 進行中 $n_run ／ 未受測 $n_block</div>
HTML

[ -f "$NOPERSIST_FLAG" ] && cat <<HTML
<div class="warn"><b>⚠ NO PERSISTENCE</b> —— 本次測試的 Evidence 只存在於記憶體，
斷電或重開機將全部失去。請立刻保存這份報告。</div>
HTML

cat <<'HTML'
<table><tr><th>裝置</th><th>序號</th><th>型號</th><th>類別</th><th>結果</th>
<th>執行狀態</th><th>溫度</th><th>說明</th></tr>
HTML

jq -r '.[] |
  "<tr><td>/dev/" + .device + "</td><td>" + .serial + "</td><td>" + .model +
  "</td><td>" + .class + "</td><td class=\"" + .result + "\">" + .result +
  (if .overridden then " <span class=\"tag\">OVERRIDE</span>" else "" end) +
  "</td><td>" + .exec_status + "</td><td>" +
  (if .baseline_temp == "" then "-" else .baseline_temp + "C → " + .final_temp + "C" end) +
  "</td><td>" + (.reasons | gsub("<";"&lt;") | gsub(">";"&gt;")) + "</td></tr>"' <<<"$rows"

echo "</table></body></html>"
} > "$OUT_DIR/summary.html.tmp" && mv "$OUT_DIR/summary.html.tmp" "$OUT_DIR/summary.html"

exit 0
