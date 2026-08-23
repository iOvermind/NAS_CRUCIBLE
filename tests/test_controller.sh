#!/bin/bash
# =========================================================================
# crucible_controller.sh 排程與 Global Abort 測試
#   以假的 device_runner.sh 取代真實執行器，驗證：
#     - wait 真的等到 runner 結束 (而非立刻返回)
#     - 退出碼聚合：2 具吸收性，不會被後續的 1 蓋掉
#     - Global Abort 真的把 runner 殺乾淨 (無孤兒進程)
#     - 沒有任何裝置受測時不得回報成功
# =========================================================================
set -u
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT

# 測試以非 root 執行，這裡把 root 防呆拿掉；其餘邏輯完全沿用正式檔案。
sed 's/^if \[ "\$EUID" -ne 0 \]; then$/if false; then/' \
    "$ROOT/crucible_controller.sh" > "$TMP/crucible_controller.sh"
chmod +x "$TMP/crucible_controller.sh"

cat > "$TMP/device_runner.sh" <<'EOF'
#!/bin/bash
# 假 runner: $1=serial $2=dev。以 FAKE_RC_<dev> 指定離開碼。
echo "$$" >> "$FAKE_PIDFILE"
trap 'exit 143' TERM
sleep "${FAKE_SLEEP:-1}"
var="FAKE_RC_$2"
exit "${!var:-0}"
EOF
chmod +x "$TMP/device_runner.sh"

pass=0; fail=0
check() {
    if [ "$2" = 0 ]; then printf "  ✅ %s\n" "$1"; pass=$((pass+1))
    else printf "  ❌ %s\n" "$1"; fail=$((fail+1)); fi
}

mkmanifest() { # mkmanifest <file> <dev:decision> ...
    local f=$1; shift
    local arr="[]"
    for spec in "$@"; do
        local d=${spec%%:*} dec=${spec##*:}
        arr=$(jq --arg d "$d" --arg dec "$dec" \
              '. + [{device:$d,serial:("SN-"+$d),protocol:"ATA",class:"SATA_HDD",decision:$dec,policy_path:"/dev/null"}]' <<<"$arr")
    done
    jq -n --argjson a "$arr" '{devices:$a}' > "$f"
}

echo "== crucible_controller.sh =="
export FAKE_PIDFILE="$TMP/pids"

# --- Case 1: wait 必須真的等待 ---
: > "$FAKE_PIDFILE"
mkmanifest "$TMP/m1.json" sdb:ALLOW sdc:ALLOW
start=$(date +%s%N)
FAKE_SLEEP=2 "$TMP/crucible_controller.sh" "$TMP/m1.json" "$TMP" >/dev/null 2>&1
rc=$?; elapsed=$(( ($(date +%s%N)-start)/1000000 ))
check "controller 等到 runner 真正結束 (耗時 ${elapsed}ms, 應 >=2000)" "$([ "$elapsed" -ge 2000 ]; echo $?)"
check "全部通過時回傳 rc=0" "$([ "$rc" -eq 0 ]; echo $?)"
check "測試結束後沒有殘留 runner 進程" \
  "$(! grep -q . "$FAKE_PIDFILE" || ! xargs -r -a "$FAKE_PIDFILE" -I{} kill -0 {} 2>/dev/null; echo $?)"

# --- Case 2: rc 聚合，2 不可被 1 蓋掉 (兩種順序都要成立) ---
mkmanifest "$TMP/m2.json" sdb:ALLOW sdc:ALLOW
FAKE_SLEEP=1 FAKE_RC_sdb=2 FAKE_RC_sdc=1 "$TMP/crucible_controller.sh" "$TMP/m2.json" "$TMP" >/dev/null 2>&1
check "rc=2 + rc=1 -> 聚合為 2 (基礎設施中止優先)" "$([ "$?" -eq 2 ]; echo $?)"
FAKE_SLEEP=1 FAKE_RC_sdb=1 FAKE_RC_sdc=2 "$TMP/crucible_controller.sh" "$TMP/m2.json" "$TMP" >/dev/null 2>&1
check "rc=1 + rc=2 -> 聚合仍為 2 (與迭代順序無關)" "$([ "$?" -eq 2 ]; echo $?)"
FAKE_SLEEP=1 FAKE_RC_sdb=1 FAKE_RC_sdc=0 "$TMP/crucible_controller.sh" "$TMP/m2.json" "$TMP" >/dev/null 2>&1
check "rc=1 + rc=0 -> 聚合為 1" "$([ "$?" -eq 1 ]; echo $?)"

# --- Case 3: Global Abort 必須真的殺掉 runner ---
: > "$FAKE_PIDFILE"
mkmanifest "$TMP/m3.json" sdb:ALLOW sdc:ALLOW
FAKE_SLEEP=60 "$TMP/crucible_controller.sh" "$TMP/m3.json" "$TMP" >/dev/null 2>&1 &
cpid=$!
sleep 1.5
n=$(wc -l < "$FAKE_PIDFILE")
check "兩個 runner 都已啟動 (實得 $n)" "$([ "$n" -eq 2 ]; echo $?)"
kill -TERM "$cpid" 2>/dev/null
wait "$cpid" 2>/dev/null; abort_rc=$?
sleep 0.5
orphans=0
while read -r p; do kill -0 "$p" 2>/dev/null && orphans=$((orphans+1)); done < "$FAKE_PIDFILE"
check "Global Abort 後沒有孤兒 runner (殘留 $orphans)" "$([ "$orphans" -eq 0 ]; echo $?)"
check "Global Abort 回傳 rc=2" "$([ "$abort_rc" -eq 2 ]; echo $?)"

# --- Case 4: 沒有裝置受測不得回報成功 ---
mkmanifest "$TMP/m4.json" sdb:BLOCK sdc:BLOCK
"$TMP/crucible_controller.sh" "$TMP/m4.json" "$TMP" >/dev/null 2>&1
check "全部被拒 -> rc=1 (不可回報成功)" "$([ "$?" -eq 1 ]; echo $?)"

mkmanifest "$TMP/m5.json" sdb:ALLOW sdc:BLOCK
FAKE_SLEEP=1 "$TMP/crucible_controller.sh" "$TMP/m5.json" "$TMP" >/dev/null 2>&1
check "部分被拒 + 其餘通過 -> rc=1" "$([ "$?" -eq 1 ]; echo $?)"

# --- Case 5: manifest 防呆 ---
echo 'not json' > "$TMP/bad.json"
"$TMP/crucible_controller.sh" "$TMP/bad.json" "$TMP" >/dev/null 2>&1
check "非法 manifest -> rc=2" "$([ "$?" -eq 2 ]; echo $?)"

echo "-------------------------------"
printf "通過 %d / 失敗 %d\n" "$pass" "$fail"
[ "$fail" -eq 0 ]
