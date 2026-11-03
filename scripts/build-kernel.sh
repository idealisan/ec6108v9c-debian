#!/usr/bin/env bash
# Build hi_kernel.bin (raw uImage + appended DTB) and modules.tar.gz for
# EC6108V9C from the pinned loonpn/ec6108v9c-linux-kernel submodule.
set -eo pipefail

KERNEL_SRC=${KERNEL_SRC:-third_party/linux-hi3798mv100}
OUT=${OUT:-build/kernel}
DIST=${DIST:-dist}
CROSS=${CROSS:-arm-linux-gnueabihf-}
DTS=${DTS:-hi3798mv100-ec6108v9c}
JOBS=${JOBS:-$(nproc 2>/dev/null || echo 4)}
LOADADDR=0x2000000

ROOT_DIR=$(cd "$(dirname "$0")/.." && pwd)
cd "$ROOT_DIR"

rm -rf "$OUT"
mkdir -p "$OUT" "$DIST"

echo "== kernel: defconfig =="
make -C "$KERNEL_SRC" O="$ROOT_DIR/$OUT" ARCH=arm CROSS_COMPILE="$CROSS" \
    hi3798mv100_defconfig

echo "== kernel: enable USB storage + SCSI built-in (live-USB root) =="
"$KERNEL_SRC/scripts/config" --file "$OUT/.config" \
    -e USB_STORAGE -e USB_UAS -e SCSI -e BLK_DEV_SD -e USB_EHCI_HCD -e USB_OHCI_HCD \
    -e EXT4_FS -e VFAT_FS -e FAT_FS
make -C "$KERNEL_SRC" O="$ROOT_DIR/$OUT" ARCH=arm CROSS_COMPILE="$CROSS" olddefconfig

echo "== kernel: build zImage / dtbs / modules =="
make -C "$KERNEL_SRC" O="$ROOT_DIR/$OUT" ARCH=arm CROSS_COMPILE="$CROSS" \
    -j"$JOBS" zImage dtbs modules

echo "== kernel: wrap zImage + DTB into uImage =="
cat "$OUT/arch/arm/boot/zImage" "$OUT/arch/arm/boot/dts/$DTS.dtb" > "$OUT/zImage-dtb"
mkimage -A arm -O linux -T kernel -C none -a $LOADADDR -e $LOADADDR \
    -n "linux-hi3798mv100" -d "$OUT/zImage-dtb" "$DIST/hi_kernel.bin"
cp -f "$OUT/zImage-dtb" "$DIST/zImage-dtb"   # raw kernel for Android boot.img wrapping

echo "== kernel: modules =="
make -C "$KERNEL_SRC" O="$ROOT_DIR/$OUT" ARCH=arm CROSS_COMPILE="$CROSS" \
    INSTALL_MOD_PATH="$ROOT_DIR/$OUT/modules" modules_install
tar -czf "$DIST/modules.tar.gz" -C "$OUT/modules" lib

echo "== kernel build results =="
ls -l "$DIST/hi_kernel.bin" "$DIST/modules.tar.gz"
