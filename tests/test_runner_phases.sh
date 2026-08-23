#!/bin/bash
# =========================================================================
# device_runner.sh 階段編排測試
#   以假 adapter 取代真實硬體操作，驗證：
#     - policy 的 phases.smart_long.enabled=false 真的能停用兩輪長測
#     - 工作負載失敗 (rc=1) 仍會產出 final_snapshot 與 verdict 證據
#     - 基礎設施中止 (rc=2) 才會連蒐證一起跳過
# =========================================================================
set -u
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
export PATH="$ROOT/tests/stubs:$PATH"

# 測試以非 root 執行，拿掉 root 防呆；其餘邏輯沿用正式檔案。
sed 's/^\[ "\$EUID" -eq 0 \] || exit 2$/:/' "$ROOT/device_runner.sh" > "$TMP/device_runner.sh"
chmod +x "$TMP/device_runner.sh"
mkdir -p "$TMP/adapters" "$TMP/lib"
cp "$ROOT/verdict_engine.sh" "$TMP/"

# --- 假 adapter：以 FAKE_RC_<phase> 控制結果，並寫出合契約的 evidence ---
cat > "$TMP/adapters/fake.sh" <<'EOF'
_ev() { # _ev <evidence_path> <rc>
    local f=$1 rc=$2 st="COMPLETED"
    [ "$rc" -eq 1 ] && st="FAILED"; [ "$rc" -ge 2 ] && st="ABORTED"
    jq -n --arg s "$st" --argjson rc "$rc" \
      '{adapter:{name:"fake",version:"1.0"},execution:{status:$s,exit_code:$rc,reason:"FAKE"}}' > "$f"
    echo "$phase_tag" >> "$FAKE_RAN"
}
_rc() { local v="FAKE_RC_$1"; echo "${!v:-0}"; }
precheck_adapter() { phase_tag=precheck; local rc; rc=$(_rc precheck)
    _ev "$4/${2}_precheck_evidence.json" "$rc"; return "$rc"; }
snapshot_adapter() { phase_tag=$4; local rc; rc=$(_rc "$4")
    _ev "$3/${2}_${4}_evidence.json" "$rc"; return "$rc"; }
smartctl_long_adapter() { phase_tag=$6; local rc; rc=$(_rc "$6")
    _ev "$4/${2}_${6}_evidence.json" "$rc"; return "$rc"; }
nvme_smart_long_adapter() { smartctl_long_adapter "$@"; }
badblocks_adapter() { phase_tag=badblocks; local rc; rc=$(_rc badblocks)
    _ev "$3/${2}_badblocks_evidence.json" "$rc"; return "$rc"; }
is_device_accessible() { return 0; }
EOF
for a in precheck snapshot smartctl_long nvme_smart_long badblocks; do
    echo 'source "$(dirname "${BASH_SOURCE[0]}")/fake.sh"' > "$TMP/adapters/${a}_adapter.sh"
done
echo ': # stub' > "$TMP/lib/device_probe.sh"

pass=0; fail=0
check() { if [ "$2" = 0 ]; then printf "  ✅ %s\n" "$1"; pass=$((pass+1))
          else printf "  ❌ %s\n" "$1"; fail=$((fail+1)); fi; }

mkpolicy() { jq -n --argjson ph "$1" \
  '{name:"T",version:"1.0",execution_profile:"X",phases:$ph,
    verdict_rules:[{name:"sp","jq_path":".smart_status.passed",check:"equals",expected:true,fail_reason:"x"}]}' \
  > "$TMP/pol.json"; }

run() { # run <log_subdir> ; 需先設好 FAKE_RC_*
    export FAKE_RAN="$TMP/$1.ran"; : > "$FAKE_RAN"
    mkdir -p "$TMP/$1"
    jq -n '{smart_status:{passed:true},temperature:{current:40}}' > "$TMP/$1/SN1_baseline_snapshot.json"
    jq -n '{smart_status:{passed:true},temperature:{current:40}}' > "$TMP/$1/SN1_final_snapshot.json"
    "$TMP/device_runner.sh" SN1 sdb ATA "$TMP/pol.json" "$TMP/$1" >/dev/null 2>&1
    echo $?
}
ran()    { grep -qx "$1" "$TMP/$2.ran"; }
phase_state() { jq -r ".execution.phases.\"$1\".status" "$TMP/$2/exec_record_SN1.json"; }

echo "== device_runner 階段編排 =="

# --- Case 1: policy 停用 smart_long ---
mkpolicy '{"smart_long":{"enabled":false},"badblocks":{"enabled":false,"timeout":10}}'
rc=$(run c1)
check "smart_long.enabled=false 真的停用 smart_long_1" \
  "$([ "$(phase_state smart_long_1 c1)" = "SKIPPED" ]; echo $?)"
check "smart_long.enabled=false 真的停用 smart_long_2" \
  "$([ "$(phase_state smart_long_2 c1)" = "SKIPPED" ]; echo $?)"
check "停用階段不會執行到 adapter" "$(! ran smart_long_1 c1; echo $?)"
check "其餘階段照常完成, rc=0 (實得 $rc)" "$([ "$rc" -eq 0 ]; echo $?)"

# --- Case 2: 工作負載失敗 (rc=1) 仍須蒐證 ---
mkpolicy '{"smart_long":{"enabled":false},"badblocks":{"enabled":true,"timeout":10}}'
FAKE_RC_badblocks=1 rc=$(FAKE_RC_badblocks=1 run c2)
check "badblocks 失敗後 final_snapshot 仍執行" \
  "$([ "$(phase_state final_snapshot c2)" = "PASS" ]; echo $?)"
check "badblocks 失敗後 verdict 仍執行" \
  "$([ "$(phase_state verdict c2)" = "PASS" ]; echo $?)"
check "verdict evidence 檔案確實產出 (壞軌時最需要的證據)" \
  "$([ -f "$TMP/c2/SN1_verdict_evidence.json" ]; echo $?)"
check "整體回傳 rc=1 (測試失敗, 非基礎設施中止) (實得 $rc)" "$([ "$rc" -eq 1 ]; echo $?)"

# --- Case 3: 基礎設施中止 (rc=2) 連蒐證一起跳過 ---
mkpolicy '{"smart_long":{"enabled":false},"badblocks":{"enabled":true,"timeout":10}}'
rc=$(FAKE_RC_badblocks=2 run c3)
check "基礎設施中止後 final_snapshot 跳過" \
  "$([ "$(phase_state final_snapshot c3)" = "SKIPPED" ]; echo $?)"
check "基礎設施中止後 verdict 跳過" \
  "$([ "$(phase_state verdict c3)" = "SKIPPED" ]; echo $?)"
check "整體回傳 rc=2 (實得 $rc)" "$([ "$rc" -eq 2 ]; echo $?)"

# --- Case 4: rc=2 具吸收性，不被後續 rc=1 蓋掉 ---
mkpolicy '{"smart_long":{"enabled":true,"timeout":5},"badblocks":{"enabled":false,"timeout":10}}'
rc=$(FAKE_RC_smart_long_1=2 run c4)
check "先 rc=2 後續階段跳過, 最終仍為 2 (實得 $rc)" "$([ "$rc" -eq 2 ]; echo $?)"

echo "-------------------------------"
printf "通過 %d / 失敗 %d\n" "$pass" "$fail"
[ "$fail" -eq 0 ]
