#!/bin/bash
# =========================================================================
# 宿主入口：建置可寫入隨身碟的 NAS_CRUCIBLE ISO
#
# 宿主唯一需要的依賴是 docker 與 git。debootstrap / xorriso / mksquashfs
# 全部只存在於容器裡。
#
# 程式碼一律取自 git archive HEAD。working tree 不乾淨時預設拒絕建置：
# 交出去的 ISO 必須能對應到一個 commit，否則三天後拿到異常 Evidence 時
# 沒有任何辦法重現當時跑的是什麼。
# =========================================================================
set -euo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
OUT_DIR="$ROOT/build/out"
ALLOW_DIRTY=false
SUITE=stable

usage() {
    cat <<EOF
用法: build/build_iso.sh [選項]

  --allow-dirty     允許在 working tree 不乾淨時建置 (ISO 會標記為 dirty)
  --out=<目錄>      ISO 輸出目錄 (預設 build/out)
  --suite=<套件庫>  Debian 套件庫 (預設 stable)
  -h, --help        顯示本說明
EOF
}

for arg in "$@"; do
    case "$arg" in
        --allow-dirty) ALLOW_DIRTY=true ;;
        --out=*)       OUT_DIR=${arg#*=} ;;
        --suite=*)     SUITE=${arg#*=} ;;
        -h|--help)     usage; exit 0 ;;
        *) echo "❌ 未知選項: $arg" >&2; usage >&2; exit 2 ;;
    esac
done

for cmd in docker git; do
    command -v "$cmd" >/dev/null 2>&1 || { echo "❌ 缺少必要指令: $cmd" >&2; exit 2; }
done

cd "$ROOT"
git rev-parse --git-dir >/dev/null 2>&1 || { echo "❌ 不在 git repo 內" >&2; exit 2; }

DIRTY=false
if [ -n "$(git status --porcelain)" ]; then
    DIRTY=true
    if [ "$ALLOW_DIRTY" != true ]; then
        echo "❌ working tree 不乾淨，拒絕建置。" >&2
        echo "   交出去的 ISO 必須對應到一個 commit，否則異常 Evidence 無從重現。" >&2
        echo "   確定要建置開發用映像請加上 --allow-dirty。" >&2
        git status --short >&2
        exit 2
    fi
    echo "⚠️  working tree 不乾淨，ISO 將標記為 dirty (僅供開發驗證，勿交付)"
fi

COMMIT=$(git rev-parse HEAD)
COMMIT_SHORT=$(git rev-parse --short HEAD)
ISO_NAME="nas_crucible_${COMMIT_SHORT}_$(date +%Y%m%d).iso"
[ "$DIRTY" = true ] && ISO_NAME="nas_crucible_${COMMIT_SHORT}-dirty_$(date +%Y%m%d).iso"

mkdir -p "$OUT_DIR"
SRC_TAR=$(mktemp "${TMPDIR:-/tmp}/crucible-src.XXXXXX.tar")
trap 'rm -f "$SRC_TAR"' EXIT
git archive --format=tar HEAD -o "$SRC_TAR"

echo "🔨 建置容器映像..."
docker build -q -t nas-crucible-build "$ROOT/build" >/dev/null

echo "🔨 建置 ISO ($COMMIT_SHORT, suite=$SUITE)..."
# debootstrap 要 mknod、chroot 要掛 proc/sys/dev，因此需要 --privileged。
docker run --rm --privileged \
    -v "$SRC_TAR:/build/src.tar:ro" \
    -v "$OUT_DIR:/out" \
    -e SUITE="$SUITE" \
    -e ISO_NAME="$ISO_NAME" \
    -e CRUCIBLE_COMMIT="$COMMIT" \
    -e CRUCIBLE_COMMIT_SHORT="$COMMIT_SHORT" \
    -e CRUCIBLE_DIRTY="$DIRTY" \
    nas-crucible-build

echo ""
echo "✅ 完成: $OUT_DIR/$ISO_NAME"
echo ""
echo "寫入隨身碟 (會抹掉該碟全部資料):"
echo "  sudo dd if=$OUT_DIR/$ISO_NAME of=/dev/sdX bs=4M status=progress oflag=sync"
echo ""
echo "首次開機時會自動在隨身碟尾端建立 Evidence Store，"
echo "因此請用容量大於 ISO 至少 512MB 的隨身碟。"
