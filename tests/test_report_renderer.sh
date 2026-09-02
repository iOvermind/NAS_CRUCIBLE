#!/bin/bash
# =========================================================================
# Summary Report 渲染器測試
#   Summary Report 是操作員唯一會真的去讀的東西。它把「還沒跑完」或「被中斷」
#   誤render成留白，就等於把失敗說成沒問題 —— 這比不產報告更危險。
# =========================================================================
set -u
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
R="$ROOT/report_renderer.sh"

pass=0; fail=0
check() { if [ "$2" = 0 ]; then printf "  ✅ %s\n" "$1"; pass=$((pass+1))
          else printf "  ❌ %s\n" "$1"; fail=$((fail+1)); fi; }

mk_manifest() { # mk_manifest <log_dir> <dev:sn:decision:reason:overridden> ...
    local ld=$1; shift; local arr="[]"
    for spec in "$@"; do
        IFS=: read -r d sn dec rsn ovr <<<"$spec"
        arr=$(jq --arg d "$d" --arg sn "$sn" --arg dec "$dec" --arg rsn "$rsn" \
                 --argjson ovr "${ovr:-false}" \
              '. + [{device:$d,serial:$sn,model:"TESTMODEL",protocol:"ATA",class:"SATA_HDD",
                     decision:$dec,block_reason:$rsn,overridable:false,overridden:$ovr,
                     policy_path:""}]' <<<"$arr")
    done
    jq -n --argjson a "$arr" '{devices:$a}' > "$ld/device_manifest.json"
}
mk_exec()    { jq -n --arg s "$2" '{serial:"x",build:{commit:"deadbee"},execution:{status:$s}}' > "$1"; }
mk_verdict() { # mk_verdict <file> <pass> <reasons...>
    local f=$1 p=$2; shift 2
    local rj="[]"; for r in "$@"; do rj=$(jq --arg r "$r" '. + [$r]' <<<"$rj"); done
    jq -n --argjson p "$p" --argjson r "$rj" \
      '{adapter:{name:"verdict",version:"1.0"},execution:{status:"COMPLETED",exit_code:0,reason:"OK"},
        observation:{overall_pass:$p,reasons:$r,baseline_temp:"30",final_temp:"41",smartctl_rc:0}}' > "$f"
}
csv_result()  { awk -F',' -v sn="\"$2\"" '$2==sn {gsub(/"/,"",$5); print $5}' "$1/summary.csv"; }
html_result() { grep -o "<td>$2</td>.*" "$1/summary.html" | grep -o 'class="[A-Z]*"' | head -1 | cut -d'"' -f2; }

echo "== 前置條件 =="
LD="$TMP/empty"; mkdir -p "$LD"
"$R" "$LD" >/dev/null 2>&1
check "manifest 不存在時回傳 2 (不得產出空報告誤導人)" "$([ $? -eq 2 ]; echo $?)"
"$R" "$TMP/nonexistent" >/dev/null 2>&1
check "log dir 不存在時回傳 2" "$([ $? -eq 2 ]; echo $?)"

echo
echo "== 混合情境 =="
LD="$TMP/mixed"; mkdir -p "$LD"
mk_manifest "$LD" \
    "sdb:SN-PASS:ALLOW::false" \
    "sdc:SN-FAIL:ALLOW::false" \
    "sdd:SN-BLOCK:BLOCK:HAS_DATA:false" \
    "sde:SN-KILLED:ALLOW::false" \
    "sdf:SN-OVR:ALLOW::true"
mk_exec "$LD/exec_record_SN-PASS.json"   COMPLETED
mk_exec "$LD/exec_record_SN-FAIL.json"   FAILED_EXECUTION
mk_exec "$LD/exec_record_SN-KILLED.json" INTERRUPTED
mk_exec "$LD/exec_record_SN-OVR.json"    COMPLETED
mk_verdict "$LD/SN-PASS_verdict_evidence.json" true
mk_verdict "$LD/SN-FAIL_verdict_evidence.json" false "reallocated_sector 由 0 增為 8"
mk_verdict "$LD/SN-OVR_verdict_evidence.json"  true
"$R" "$LD" >/dev/null 2>&1
check "產生 summary.csv"  "$([ -f "$LD/summary.csv" ]; echo $?)"
check "產生 summary.html" "$([ -f "$LD/summary.html" ]; echo $?)"
check "PASS 的碟判為 PASS"       "$([ "$(csv_result "$LD" SN-PASS)"  = PASS ]; echo $?)"
check "FAIL 的碟判為 FAIL"       "$([ "$(csv_result "$LD" SN-FAIL)"  = FAIL ]; echo $?)"
check "被擋的碟判為 BLOCKED"     "$([ "$(csv_result "$LD" SN-BLOCK)" = BLOCKED ]; echo $?)"
check "被擋的碟帶上封鎖原因"     "$(grep -q 'HAS_DATA' "$LD/summary.csv"; echo $?)"

# 這是整支渲染器最關鍵的一條：被中斷、沒有 verdict evidence 的碟不得留白。
check "被中斷且無 verdict evidence 的碟判為 FAIL (不得留白)" \
      "$([ "$(csv_result "$LD" SN-KILLED)" = FAIL ]; echo $?)"
check "並說明為什麼 (未產出 verdict evidence)" \
      "$(grep -q '未產出 verdict evidence' "$LD/summary.csv"; echo $?)"
check "Override 的碟在 HTML 上看得出來" \
      "$(grep -q 'OVERRIDE' "$LD/summary.html"; echo $?)"
check "CSV 行數 = 標頭 + 5 顆碟" \
      "$([ "$(grep -c '' "$LD/summary.csv")" = 6 ]; echo $?)"
check "CSV 帶 UTF-8 BOM (Excel 開啟不亂碼)" \
      "$(head -c3 "$LD/summary.csv" | grep -q $'\xef\xbb\xbf'; echo $?)"

echo
echo "== CSV 與 HTML 必須同源 =="
for sn in SN-PASS SN-FAIL SN-BLOCK SN-KILLED; do
    c=$(csv_result "$LD" "$sn"); h=$(html_result "$LD" "$sn")
    check "$sn: CSV=$c HTML=$h 一致" "$([ "$c" = "$h" ]; echo $?)"
done

echo
echo "== 可重複執行 (每顆碟跑完都會重繪一次) =="
cp "$LD/summary.csv" "$TMP/first.csv"
"$R" "$LD" >/dev/null 2>&1
check "重跑產生相同 CSV" "$(diff -q "$TMP/first.csv" "$LD/summary.csv" >/dev/null; echo $?)"

echo
echo "== 部分完成 (中途斷電的實況) =="
LD="$TMP/partial"; mkdir -p "$LD"
mk_manifest "$LD" "sdb:SN-DONE:ALLOW::false" "sdc:SN-RUNNING:ALLOW::false"
mk_exec "$LD/exec_record_SN-DONE.json"    COMPLETED
mk_exec "$LD/exec_record_SN-RUNNING.json" RUNNING
mk_verdict "$LD/SN-DONE_verdict_evidence.json" true
"$R" "$LD" >/dev/null 2>&1
check "已跑完的碟已有結論" "$([ "$(csv_result "$LD" SN-DONE)" = PASS ]; echo $?)"
check "還在跑的碟標為 RUNNING (不是 PASS 也不是留白)" \
      "$([ "$(csv_result "$LD" SN-RUNNING)" = RUNNING ]; echo $?)"

echo
echo "== 輸出目錄可分離 (Live 下寫到 FAT32 摘要分區) =="
OUT="$TMP/report"; "$R" "$LD" "$OUT" >/dev/null 2>&1
check "摘要寫到指定的 out_dir" "$([ -f "$OUT/summary.html" ] && [ -f "$OUT/summary.csv" ]; echo $?)"
check "不污染 log dir 以外的既有 Evidence" \
      "$([ -f "$LD/exec_record_SN-DONE.json" ]; echo $?)"

echo
echo "== HTML 跳脫 =="
LD="$TMP/escape"; mkdir -p "$LD"
mk_manifest "$LD" "sdb:SN-X:ALLOW::false"
mk_exec "$LD/exec_record_SN-X.json" FAILED_EXECUTION
mk_verdict "$LD/SN-X_verdict_evidence.json" false '<script>alert(1)</script>'
"$R" "$LD" >/dev/null 2>&1
check "reasons 內的角括號被跳脫" \
      "$(grep -q '&lt;script&gt;' "$LD/summary.html" && ! grep -q '<script>alert' "$LD/summary.html"; echo $?)"

echo "-------------------------------"
printf "通過 %d / 失敗 %d\n" "$pass" "$fail"
[ "$fail" -eq 0 ]
