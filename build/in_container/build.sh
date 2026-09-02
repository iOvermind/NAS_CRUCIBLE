#!/bin/bash
# =========================================================================
# 在容器內建置 NAS_CRUCIBLE live image (debootstrap -> squashfs -> hybrid ISO)
#
# 為什麼不用 live-build：這裡的每一步都要能被 tests/test_build_contract.sh
# 靜態檢查，而 live-build 把開機鏈組裝藏在自己的 config 樹裡。手寫這段的代價
# 是多一百行，換來的是「Secure Boot 用哪個 shim、BIOS 走哪條路徑」全部看得見。
# =========================================================================
set -euo pipefail

SRC_TAR=${SRC_TAR:-/build/src.tar}
OUT_DIR=${OUT_DIR:-/out}
SUITE=${SUITE:-stable}
MIRROR=${MIRROR:-http://deb.debian.org/debian}
ISO_NAME=${ISO_NAME:-nas_crucible.iso}
COMMIT=${CRUCIBLE_COMMIT:-unknown}
COMMIT_SHORT=${CRUCIBLE_COMMIT_SHORT:-unknown}
DIRTY=${CRUCIBLE_DIRTY:-false}

WORK=/work
CHROOT="$WORK/chroot"
ISO_TREE="$WORK/iso"
CRUCIBLE_DIR="$CHROOT/opt/nas_crucible"

step() { echo ""; echo "### $*"; }

cleanup() {
    for m in dev/pts dev proc sys run; do
        mountpoint -q "$CHROOT/$m" && umount -lf "$CHROOT/$m" || true
    done
}
trap cleanup EXIT

rm -rf "$WORK"; mkdir -p "$CHROOT" "$ISO_TREE" "$OUT_DIR"

# --- 1. 最小系統 -------------------------------------------------------
step "debootstrap $SUITE"
debootstrap --variant=minbase --arch=amd64 "$SUITE" "$CHROOT" "$MIRROR"

cat > "$CHROOT/etc/apt/sources.list" <<EOF
deb $MIRROR $SUITE main contrib
deb $MIRROR ${SUITE}-updates main contrib
deb http://security.debian.org/debian-security ${SUITE}-security main contrib
EOF

mount -t proc  none "$CHROOT/proc"
mount -t sysfs none "$CHROOT/sys"
mount --bind /dev "$CHROOT/dev"
mount -t devpts none "$CHROOT/dev/pts"

# 建置期間不要讓套件的 postinst 去啟動服務。
printf '#!/bin/sh\nexit 101\n' > "$CHROOT/usr/sbin/policy-rc.d"
chmod +x "$CHROOT/usr/sbin/policy-rc.d"

# --- 2. 套件 -----------------------------------------------------------
step "安裝套件"
PKGS=$(grep -vE '^\s*(#|$)' /build/packages.list | tr '\n' ' ')
echo "  $PKGS"
chroot "$CHROOT" /bin/bash -c "
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq
    apt-get install -y --no-install-recommends $PKGS
"

# --- 3. 專案程式碼 ------------------------------------------------------
# 一律來自 git archive HEAD：交出去的 ISO 必須能對應到一個 commit，
# 否則三天後拿到異常 Evidence 時無從重現。見 docs/adr 與 build_iso.sh。
step "植入 NAS_CRUCIBLE ($COMMIT_SHORT)"
mkdir -p "$CRUCIBLE_DIR"
tar -xf "$SRC_TAR" -C "$CRUCIBLE_DIR"
chmod +x "$CRUCIBLE_DIR"/*.sh "$CRUCIBLE_DIR"/adapters/*.sh

cat > "$CRUCIBLE_DIR/build_info.json" <<EOF
{
  "commit": "$COMMIT",
  "commit_short": "$COMMIT_SHORT",
  "dirty": $DIRTY,
  "built_at": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "debian_suite": "$SUITE",
  "debian_version": "$(cat "$CHROOT/etc/debian_version")"
}
EOF

# --- 4. Live 專屬設定 ---------------------------------------------------
step "疊加 live rootfs 設定"
cp -a /build/rootfs/. "$CHROOT/"
chmod +x "$CHROOT/usr/local/sbin/crucible-evidence-store" \
         "$CHROOT/usr/local/sbin/crucible-autostart"

chroot "$CHROOT" ln -sf /usr/local/sbin/crucible-autostart /usr/local/sbin/crucible
mkdir -p "$CHROOT/etc/systemd/system/multi-user.target.wants"
chroot "$CHROOT" ln -sf /etc/systemd/system/crucible-evidence-store.service \
    /etc/systemd/system/multi-user.target.wants/crucible-evidence-store.service

echo "nas-crucible" > "$CHROOT/etc/hostname"
chroot "$CHROOT" passwd -d root
# 沒有網路，也不要有任何監聽服務。見 TODO.md：v1 完全無網路。
chroot "$CHROOT" systemctl mask systemd-networkd.service systemd-resolved.service 2>/dev/null || true

step "產生 initramfs"
chroot "$CHROOT" update-initramfs -u -k all

# --- 5. 收尾與 squashfs -------------------------------------------------
step "清理並壓成 squashfs"
chroot "$CHROOT" apt-get clean
rm -f "$CHROOT/usr/sbin/policy-rc.d"
rm -rf "$CHROOT/var/lib/apt/lists"/* "$CHROOT/tmp"/*
cleanup

mkdir -p "$ISO_TREE/live"
mksquashfs "$CHROOT" "$ISO_TREE/live/filesystem.squashfs" -comp xz -noappend -quiet
cp "$CHROOT"/boot/vmlinuz-* "$ISO_TREE/live/vmlinuz"
cp "$CHROOT"/boot/initrd.img-* "$ISO_TREE/live/initrd.img"

# --- 6. BIOS 開機路徑 (isolinux) ---------------------------------------
step "組裝 BIOS 開機路徑"
mkdir -p "$ISO_TREE/isolinux"
cp "$CHROOT/usr/lib/ISOLINUX/isolinux.bin" "$ISO_TREE/isolinux/"
cp "$CHROOT"/usr/lib/syslinux/modules/bios/{menu.c32,libutil.c32,ldlinux.c32} "$ISO_TREE/isolinux/"
cp /build/boot/isolinux.cfg "$ISO_TREE/isolinux/"

# --- 7. UEFI 開機路徑 (shim -> grub -> 官方簽章 kernel) ------------------
# 用 Debian 官方簽章的 shim 與 grub，開著 Secure Boot 也能開機。見 docs/adr/0002。
step "組裝 UEFI 開機路徑 (Secure Boot)"
mkdir -p "$ISO_TREE/boot/grub" "$WORK/efi/EFI/BOOT" "$WORK/efi/EFI/debian"
cp /build/boot/grub.cfg "$ISO_TREE/boot/grub/grub.cfg"

cp "$CHROOT/usr/lib/shim/shimx64.efi.signed"          "$WORK/efi/EFI/BOOT/BOOTX64.EFI"
cp "$CHROOT/usr/lib/shim/mmx64.efi.signed"            "$WORK/efi/EFI/BOOT/mmx64.efi"
cp "$CHROOT/usr/lib/grub/x86_64-efi-signed/grubx64.efi.signed" "$WORK/efi/EFI/BOOT/grubx64.efi"

# Debian 簽章版 grub 的 prefix 固定是 /EFI/debian，只能在那裡放設定；
# 真正的選單留在 ISO 上，這裡只負責把 root 指過去。
cat > "$WORK/efi/EFI/debian/grub.cfg" <<'EOF'
search --set=root --file /live/vmlinuz
set prefix=($root)/boot/grub
configfile /boot/grub/grub.cfg
EOF

# El Torito 的 EFI 開機映像必須是一個 FAT 檔案系統映像。
efi_kb=$(( ($(du -sk "$WORK/efi" | cut -f1) + 1024) * 2 ))
mkfs.vfat -C "$ISO_TREE/boot/efi.img" "$efi_kb" >/dev/null
mcopy -s -i "$ISO_TREE/boot/efi.img" "$WORK/efi/EFI" ::

# --- 8. Hybrid ISO ------------------------------------------------------
step "產生 hybrid ISO"
mkdir -p "$ISO_TREE/.disk"
echo "NAS_CRUCIBLE $COMMIT_SHORT" > "$ISO_TREE/.disk/info"

xorriso -as mkisofs \
    -iso-level 3 \
    -volid "NAS_CRUCIBLE" \
    -eltorito-boot isolinux/isolinux.bin \
    -eltorito-catalog isolinux/boot.cat \
    -no-emul-boot -boot-load-size 4 -boot-info-table \
    -isohybrid-mbr "$CHROOT/usr/lib/ISOLINUX/isohdpfx.bin" \
    -eltorito-alt-boot \
    -e boot/efi.img \
    -no-emul-boot \
    -isohybrid-gpt-basdat \
    -output "$OUT_DIR/$ISO_NAME" \
    "$ISO_TREE"

( cd "$OUT_DIR" && sha256sum "$ISO_NAME" > "${ISO_NAME}.sha256" )

step "完成"
ls -lh "$OUT_DIR/$ISO_NAME"
cat "$OUT_DIR/${ISO_NAME}.sha256"
