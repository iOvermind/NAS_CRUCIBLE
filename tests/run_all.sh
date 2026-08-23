#!/bin/bash
# 執行所有不需要真實硬體的測試
set -u
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
rc=0

echo "### 語法檢查 (bash -n)"
while IFS= read -r f; do
    if bash -n "$f" 2>/dev/null; then printf "  ✅ %s\n" "${f#$ROOT/}"
    else printf "  ❌ %s\n" "${f#$ROOT/}"; rc=1; fi
done < <(find "$ROOT" -name '*.sh' -not -path '*/legacy/*' -not -path '*/tests/stubs/*' | sort)

echo
echo "### Policy JSON 合法性"
while IFS= read -r f; do
    if jq -e '.name and .version and .execution_profile and (.verdict_rules|type=="array")' "$f" >/dev/null 2>&1; then
        printf "  ✅ %s\n" "${f#$ROOT/}"
    else printf "  ❌ %s\n" "${f#$ROOT/}"; rc=1; fi
done < <(find "$ROOT/policies" -name '*.json' | sort)

echo
for t in "$ROOT"/tests/test_*.sh; do
    echo "### $(basename "$t")"
    "$t" || rc=1
    echo
done

[ "$rc" -eq 0 ] && echo "🎉 全部通過" || echo "💥 有測試失敗"
exit "$rc"
