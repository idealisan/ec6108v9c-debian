#!/usr/bin/env bash
# Build hi_kernel.bin (uImage = zImage + appended DTB) and modules.tar.gz for
# EC6108V9C from the pinned loonpn/ec6108v9c-linux-kernel submodule, with our
# local patches applied (simple-framebuffer, Tsensor, rtl8xxxu support).
set -eo pipefail

KERNEL_SRC=${KERNEL_SRC:-third_party/linux-hi3798mv100}
OUT=${OUT:-build/kernel}
DIST=${DIST:-dist}
CROSS=${CROSS:-arm-linux-gnueabihf-}
DTS=${DTS:-hi3798mv100-ec6108v9c}
JOBS=${JOBS:-$(nproc 2>/dev/null || echo 4)}
LOADADDR=0x2000000
# Framebuffer left by hiboot. Leave empty (node disabled) until the physical
# address is confirmed from the boot log; set FB_BASE=0x3xxxxxxx to enable HDMI
# console. CI exposes this as a workflow_dispatch input.
FB_BASE=${FB_BASE:-}
PATCH_DIR=${PATCH_DIR:-patches/kernel}
CONFIG_FRAGMENT=${CONFIG_FRAGMENT:-configs/kernel/ec6108v9c.config}

ROOT_DIR=$(cd "$(dirname "$0")/.." && pwd)
cd "$ROOT_DIR"

# Shared partition / memory layout (also used by the flash package script),
# so the DTB command line and the p2 runtime env can never drift apart.
# LAYOUT_ENV selects the partition layout: the merged one we ship by
# default, or the community one for diagnostic kernels.
LAYOUT_ENV=${LAYOUT_ENV:-configs/partition-layout.env}
if [ -f "$ROOT_DIR/$LAYOUT_ENV" ]; then
  echo "  layout: $LAYOUT_ENV"
  set -a
  . "$ROOT_DIR/$LAYOUT_ENV"
  set +a
fi

rm -rf "$OUT"
mkdir -p "$OUT" "$DIST"

echo "== kernel: apply local patches =="
# The submodule is a checkout with its own .git; git apply keeps the original
# tree untouched (CI re-checkouts on every run). Use absolute patch paths.
git -C "$KERNEL_SRC" apply \
  "$ROOT_DIR/$PATCH_DIR/0001-ec6108v9c-dts-simplefb-tsensor.patch" \
  "$ROOT_DIR/$PATCH_DIR/0002-thermal-kconfig-makefile.patch"
cp "$PATCH_DIR/hi3798mv100_tsensor.c" "$KERNEL_SRC/drivers/thermal/"

echo "== kernel: substitute framebuffer base/status in DTS =="
DTS_FILE="$KERNEL_SRC/arch/arm/boot/dts/$DTS.dts"
if [ -n "$FB_BASE" ]; then
  echo "  HDMI framebuffer at $FB_BASE (simplefb + fbcon enabled)"
else
  echo "  FB_BASE unset: framebuffer nodes omitted (safe default)"
fi
python3 scripts/apply-dts-placeholders.py "$DTS_FILE" "$PATCH_DIR/simple-framebuffer.dtsi"     "$FB_BASE" "${KERNEL_CMDLINE:-}" "${MEM_SIZE:-0x40000000}"
grep -n "tsensor\|simple-framebuffer\|memory@0\|bootargs" "$DTS_FILE" | head -8

echo "== kernel: defconfig =="
make -C "$KERNEL_SRC" O="$ROOT_DIR/$OUT" ARCH=arm CROSS_COMPILE="$CROSS" \
    hi3798mv100_defconfig

echo "== kernel: merge config fragment =="
# scripts/config turns each "CONFIG_X=y/m/string" line into .config edits.
# Comments (# ...) are skipped by scripts/config naturally.
"$KERNEL_SRC/scripts/config" --file "$OUT/.config" \
    -e USB_STORAGE -e USB_UAS -e SCSI -e BLK_DEV_SD -e USB_EHCI_HCD -e USB_OHCI_HCD \
    -e EXT4_FS -e VFAT_FS -e FAT_FS
# apply the fragment
while IFS= read -r line; do
  case "$line" in
    CONFIG_*) ;;
    *) continue ;;
  esac
  key=${line%%=*}
  val=${line#*=}
  case "$val" in
    y) "$KERNEL_SRC/scripts/config" --file "$OUT/.config" -e "${key#CONFIG_}" ;;
    m) "$KERNEL_SRC/scripts/config" --file "$OUT/.config" -m "${key#CONFIG_}" ;;
    n) "$KERNEL_SRC/scripts/config" --file "$OUT/.config" -d "${key#CONFIG_}" ;;
    "*") "$KERNEL_SRC/scripts/config" --file "$OUT/.config" --set-str "${key#CONFIG_}" "${val//\"/}" ;;
    *) echo "  (skip $line)" ;;
  esac
done < "$CONFIG_FRAGMENT"
make -C "$KERNEL_SRC" O="$ROOT_DIR/$OUT" ARCH=arm CROSS_COMPILE="$CROSS" olddefconfig
echo "== kernel: verify key options =="
grep -E "^(CONFIG_RTL8XXXU|CONFIG_FB_SIMPLE|CONFIG_FRAMEBUFFER_CONSOLE|CONFIG_THERMAL=|CONFIG_HI3798MV100_TSENSOR|CONFIG_EXT4_FS|CONFIG_BTRFS_FS|CONFIG_NTFS3_FS|CONFIG_EXFAT_FS|CONFIG_USB_HID)=" "$OUT/.config"

echo "== kernel: build zImage / dtbs / modules =="
make -C "$KERNEL_SRC" O="$ROOT_DIR/$OUT" ARCH=arm CROSS_COMPILE="$CROSS" \
    -j"$JOBS" zImage dtbs modules

echo "== kernel: wrap zImage + DTB into uImage =="
# KERNEL_OUT lets a second build (e.g. the diagnostic community-layout
# kernel) write to its own file instead of overwriting the shipped one.
KERNEL_OUT=${KERNEL_OUT:-$DIST/hi_kernel.bin}
mkdir -p "$(dirname "$KERNEL_OUT")"
cat "$OUT/arch/arm/boot/zImage" "$OUT/arch/arm/boot/dts/$DTS.dtb" > "$OUT/zImage-dtb"
mkimage -A arm -O linux -T kernel -C none -a $LOADADDR -e $LOADADDR \
    -n "linux-hi3798mv100" -d "$OUT/zImage-dtb" "$KERNEL_OUT"
cp -f "$OUT/zImage-dtb" "$OUT/zImage-dtb.out"

if [ "${SKIP_MODULES:-0}" = "1" ]; then
  echo "== kernel: modules skipped (diagnostic build) =="
else
  echo "== kernel: modules =="
  make -C "$KERNEL_SRC" O="$ROOT_DIR/$OUT" ARCH=arm CROSS_COMPILE="$CROSS" \
      INSTALL_MOD_PATH="$ROOT_DIR/$OUT/modules" modules_install
  tar -czf "$DIST/modules.tar.gz" -C "$OUT/modules" lib
fi

echo "== kernel build results =="
ls -l "$KERNEL_OUT"
