#!/bin/bash
# =========================================================================
# nvme_smart_long_adapter 契約測試 (以 stub 取代 nvme-cli / smartctl)
#   驗證: Evidence 檔名契約、輪詢狀態機、abort 指令形狀、逾時與失敗分類。
# =========================================================================
set -u
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
export PATH="$ROOT/tests/stubs:$PATH"
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT

source "$ROOT/adapters/nvme_smart_long_adapter.sh"
# 測試環境沒有真實區塊裝置，覆寫探針 (production code 不含測試掛勾)
is_device_accessible() { return "${FAKE_DEV_GONE:-0}"; }

pass=0; fail=0
check() { # check <說明> <條件結果>
    if [ "$2" = 0 ]; then printf "  ✅ %s\n" "$1"; pass=$((pass+1))
    else printf "  ❌ %s\n" "$1"; fail=$((fail+1)); fi
}

echo "== nvme_smart_long_adapter =="

# --- Case 1: 正常完成 ---
export STUB_POLL_COUNT="$TMP/c1" STUB_NVME_CALLS="$TMP/calls1" STUB_RUNNING_POLLS=2
SMART_POLL_INTERVAL=1 nvme_smart_long_adapter nvme0n1 SN123 NVMe "$TMP" 3600 smart_long_1
rc=$?
EV="$TMP/SN123_smart_long_1_evidence.json"

check "Evidence 寫在 runner 契約的 \${serial}_\${phase}_evidence.json" "$([ -f "$EV" ]; echo $?)"
check "正常完成回傳 rc=0" "$([ "$rc" -eq 0 ]; echo $?)"
check "execution.reason=COMPLETED_SUCCESSFULLY" \
  "$(jq -e '.execution.reason=="COMPLETED_SUCCESSFULLY"' "$EV" >/dev/null; echo $?)"
check "observation 取得 self-test 結果字串" \
  "$(jq -e '.observation.self_test_result=="Completed without error"' "$EV" >/dev/null; echo $?)"
check "啟動用 extended self-test code 2" \
  "$(grep -q -- '-s 2 /dev/nvme0n1' "$TMP/calls1"; echo $?)"
check "正常路徑不得送出 abort" \
  "$(! grep -q -- '-s 0xf' "$TMP/calls1"; echo $?)"
check "smart_long_2 會產出獨立 Evidence (不覆蓋 smart_long_1)" \
  "$(export STUB_POLL_COUNT="$TMP/c2" STUB_NVME_CALLS="$TMP/calls2";
     SMART_POLL_INTERVAL=1 nvme_smart_long_adapter nvme0n1 SN123 NVMe "$TMP" 3600 smart_long_2 >/dev/null 2>&1
     [ -f "$TMP/SN123_smart_long_2_evidence.json" ] && [ -f "$EV" ]; echo $?)"

# --- Case 2: 逾時必須送出 abort 並判 ABORTED ---
export STUB_POLL_COUNT="$TMP/c3" STUB_NVME_CALLS="$TMP/calls3" STUB_RUNNING_POLLS=9999
SMART_POLL_INTERVAL=1 nvme_smart_long_adapter nvme0n1 SN999 NVMe "$TMP" 2 smart_long_1
rc=$?
EV2="$TMP/SN999_smart_long_1_evidence.json"
check "逾時回傳 rc=2 (Fail-Closed)" "$([ "$rc" -eq 2 ]; echo $?)"
check "逾時 reason=WORKLOAD_TIMEOUT_OR_ENVIRONMENT_FAILURE" \
  "$(jq -e '.execution.reason=="WORKLOAD_TIMEOUT_OR_ENVIRONMENT_FAILURE"' "$EV2" >/dev/null; echo $?)"
check "逾時必須以 -s 0xf 送出 abort (非 --action=abort)" \
  "$(grep -q -- '-s 0xf /dev/nvme0n1' "$TMP/calls3"; echo $?)"
check "逾時 evidence 標記 abort.requested=true" \
  "$(jq -e '.abort.requested==true' "$EV2" >/dev/null; echo $?)"

# --- Case 3: 韌體不支援 self-test log -> 絕不可誤判為 COMPLETE ---
check "self-test log 結構不明時解析為 UNKNOWN" \
  "$([ "$(_parse_nvme_selftest_state '{"foo":1}')" = "UNKNOWN" ]; echo $?)"
check "current_self_test_operation!=0 解析為 RUNNING" \
  "$([ "$(_parse_nvme_selftest_state '{"nvme_self_test_log":{"current_self_test_operation":{"value":2}}}')" = "RUNNING" ]; echo $?)"

# --- Case 4: 裝置消失 ---
export STUB_POLL_COUNT="$TMP/c4" STUB_NVME_CALLS="$TMP/calls4" STUB_RUNNING_POLLS=9999
FAKE_DEV_GONE=1 SMART_POLL_INTERVAL=1 nvme_smart_long_adapter nvme0n1 SNGONE NVMe "$TMP" 3600 smart_long_1
rc=$?
check "裝置失聯回傳 rc=2 並歸類為基礎設施故障" \
  "$([ "$rc" -eq 2 ] && jq -e '.execution.reason=="INFRASTRUCTURE_DEVICE_LOST_OR_TRANSPORT_BROKEN"' \
      "$TMP/SNGONE_smart_long_1_evidence.json" >/dev/null; echo $?)"

echo "-------------------------------"
printf "通過 %d / 失敗 %d\n" "$pass" "$fail"
[ "$fail" -eq 0 ]
