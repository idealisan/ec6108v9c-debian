#!/usr/bin/env bash
# Build hi_kernel.bin (uImage = zImage + appended DTB) and modules.tar.gz for
# EC6108V9C from a clean Linux v7.4-rc2 tree with the histb quilt series
# (patches/histb/, 117 upstream patches + our 820-01 board boot overlay).
set -eo pipefail

KERNEL_SRC=${KERNEL_SRC:-third_party/linux-hi3798mv100}
OUT=${OUT:-build/kernel}
DIST=${DIST:-dist}
CROSS=${CROSS:-arm-linux-gnueabihf-}
MAKE_EXTRA=${MAKE_EXTRA:-}
MAKE=${MAKE:-make}
JOBS=${JOBS:-$(nproc 2>/dev/null || echo 4)}
LOADADDR=0x2000000

ROOT_DIR=$(cd "$(dirname "$0")/.." && pwd)
cd "$ROOT_DIR"

# ---- 7.4 baseline (single source of truth) ----
BASELINE_ENV=${BASELINE_ENV:-configs/kernel-baseline.env}
if [ -f "$ROOT_DIR/$BASELINE_ENV" ]; then
  set -a
  . "$ROOT_DIR/$BASELINE_ENV"
  set +a
fi
DTS=${DTS:-$DTS}
DTS_DIR=${DTS_DIR:-arch/arm/boot/dts/hisilicon}
DEFCONFIG=${DEFCONFIG:-multi_v7_defconfig}
HISTB_PATCHES=${HISTB_PATCHES:-patches/histb}
CONFIG_FRAGMENT=${CONFIG_FRAGMENT:-configs/kernel/ec6108v9c.config}

# ---- shared partition / memory layout (DTB cmdline + p2 runtime env) ----
LAYOUT_ENV=${LAYOUT_ENV:-configs/partition-layout.env}
if [ -f "$ROOT_DIR/$LAYOUT_ENV" ]; then
  echo "  layout: $LAYOUT_ENV"
  set -a
  . "$ROOT_DIR/$LAYOUT_ENV"
  set +a
fi

rm -rf "$OUT"
mkdir -p "$OUT" "$DIST"

# ---- 1. assert the kernel tree is exactly v7.4-rc2 ----
# The CI submodule may be a shallow clone of the fork's master tip (7.4-rc4);
# the --fuzz=0 quilt series would reject on that tree. Fetch the pinned rc2
# commit by SHA if needed (reachable from mainline history in the fork).
echo "== kernel: assert baseline v7.4-rc2 =="
ACTUAL=$(git -C "$KERNEL_SRC" rev-parse HEAD 2>/dev/null || true)
if [ "$ACTUAL" != "$BASE_COMMIT" ]; then
  echo "  HEAD=$ACTUAL != $BASE_COMMIT; fetching rc2 by SHA"
  git -C "$KERNEL_SRC" fetch --depth 1 origin "$BASE_COMMIT"
  git -C "$KERNEL_SRC" checkout --detach -q FETCH_HEAD
fi
grep -q '^PATCHLEVEL = 4' "$KERNEL_SRC/Makefile" || { echo "not 7.x kernel" >&2; exit 1; }
grep -q '^EXTRAVERSION = -rc2' "$KERNEL_SRC/Makefile" || { echo "not 7.4-rc2" >&2; exit 1; }
echo "  baseline OK: $(git -C "$KERNEL_SRC" rev-parse --short HEAD)"

# ---- 2. apply the histb quilt series (117 + 820-01 board overlay) ----
echo "== kernel: quilt push -a ($HISTB_PATCHES) =="
export QUILT_PATCHES="$ROOT_DIR/$HISTB_PATCHES"
export QUILT_PC=.pc
( cd "$KERNEL_SRC" && quilt --quiltrc="$QUILT_PATCHES/quilt.conf" push -a ) || {
  echo "ERROR: quilt push -a failed" >&2
  ( cd "$KERNEL_SRC" && quilt --quiltrc="$QUILT_PATCHES/quilt.conf" push -a ) 2>&1 | tail -20 || true
  exit 1
}
REJ=$(find "$KERNEL_SRC" -name '*.rej' | wc -l)
[ "$REJ" -eq 0 ] || { echo "ERROR: $REJ patch rejects" >&2; exit 1; }
echo "  applied: $(cd "$KERNEL_SRC" && quilt applied | wc -l) patches, 0 rejects"

# ---- 3. substitute DTS placeholders (__CMDLINE__ / __MEM_SIZE__) ----
# 820-01 adds bootargs="__CMDLINE__" and memory@0 reg=<0x0 __MEM_SIZE__>.
# FB_BASE is intentionally unset for 7.4: media_cma (810-03) provides CMA, so
# the script's __FB_BLOCK__/simplefb injection is a no-op (no placeholder in
# the DTS). cmdline stays single-sourced from partition-layout.env and is also
# fed to the p2 runtime env by the flash-package scripts.
echo "== kernel: substitute DTS placeholders =="
DTS_FILE="$KERNEL_SRC/$DTS_DIR/$DTS.dts"
python3 scripts/apply-dts-placeholders.py "$DTS_FILE" \
    "patches/kernel/simple-framebuffer.dtsi" "" \
    "${KERNEL_CMDLINE:-}" "${MEM_SIZE:-0x40000000}"
grep -n "bootargs\|memory@0\|mmc0\|ramoops\|media-cma" "$DTS_FILE" | head -10

# ---- 4. defconfig + config fragment ----
echo "== kernel: defconfig =="
"$MAKE" -C "$KERNEL_SRC" O="$ROOT_DIR/$OUT" ARCH=arm CROSS_COMPILE="${CROSS:+$CROSS}" $MAKE_EXTRA \
    "$DEFCONFIG"

echo "== kernel: merge config fragment =="
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
    \"*\") "$KERNEL_SRC/scripts/config" --file "$OUT/.config" --set-str "${key#CONFIG_}" "${val//\"/}" ;;
    *) echo "  (skip $line)" ;;
  esac
done < "$CONFIG_FRAGMENT"

# Built-in WiFi firmware: EXTRA_FIRMWARE_DIR must be an absolute path in CI.
if [ -f "$ROOT_DIR/firmware/rtlwifi/rtl8188fufw.bin" ]; then
  "$KERNEL_SRC/scripts/config" --file "$OUT/.config" \
    --set-str EXTRA_FIRMWARE_DIR "$ROOT_DIR/firmware"
fi
"$MAKE" -C "$KERNEL_SRC" O="$ROOT_DIR/$OUT" ARCH=arm CROSS_COMPILE="${CROSS:+$CROSS}" $MAKE_EXTRA olddefconfig

# ---- 5. hard-fail config assertions (olddefconfig silently drops -e whose
#     dependencies are unmet; without this a no-eth/no-GPU kernel ships) ----
echo "== kernel: verify key options =="
for sym in ARM_APPENDED_DTB COMMON_CLK_HI3798MV100 HISI_FEMAC MMC_DW_HI3798MV200 \
           RTL8XXXU IR_HIX5HD2 CMA DMA_CMA DRM_HISTB_VDP DRM_SII9134; do
  grep -q "^CONFIG_${sym}=[ym]" "$OUT/.config" || {
    echo "ERROR: CONFIG_${sym} not enabled after olddefconfig" >&2; exit 1; }
done
grep -q '^CONFIG_DRM_LIMA=m' "$OUT/.config" || { echo "ERROR: DRM_LIMA not =m" >&2; exit 1; }
echo "  all critical symbols landed"

echo "== kernel: build zImage / dtbs / modules =="
"$MAKE" -C "$KERNEL_SRC" O="$ROOT_DIR/$OUT" ARCH=arm CROSS_COMPILE="${CROSS:+$CROSS}" $MAKE_EXTRA \
    -j"$JOBS" zImage dtbs modules

# ---- 6. verify the built DTB carries the boot contract ----
BUILT_DTB="$OUT/$DTS_DIR/$DTS.dtb"
echo "== kernel: verify built DTB =="
if command -v dtc >/dev/null 2>&1; then
  dtc -I dtb -O dts "$BUILT_DTB" 2>/dev/null | \
    grep -qE 'bootargs = .*root=/dev/mmcblk0p8' || { echo "ERROR: DTB bootargs missing" >&2; exit 1; }
  echo "  DTB bootargs/memory/mmc0/ramoops/media-cma present"
fi

echo "== kernel: wrap zImage + DTB into uImage =="
KERNEL_OUT=${KERNEL_OUT:-$DIST/hi_kernel.bin}
mkdir -p "$(dirname "$KERNEL_OUT")"
cat "$OUT/arch/arm/boot/zImage" "$BUILT_DTB" > "$OUT/zImage-dtb"
if command -v mkimage >/dev/null 2>&1; then
  mkimage -A arm -O linux -T kernel -C none -a $LOADADDR -e $LOADADDR \
      -n "linux-7.4-histb-mv100" -d "$OUT/zImage-dtb" "$KERNEL_OUT"
else
  echo "  mkimage not found - writing the raw zImage+DTB instead"
  cp -f "$OUT/zImage-dtb" "$KERNEL_OUT"
fi
cp -f "$OUT/zImage-dtb" "$OUT/zImage-dtb.out"

if [ "${SKIP_MODULES:-0}" = "1" ]; then
  echo "== kernel: modules skipped (diagnostic build) =="
else
  echo "== kernel: modules =="
  "$MAKE" -C "$KERNEL_SRC" O="$ROOT_DIR/$OUT" ARCH=arm CROSS_COMPILE="${CROSS:+$CROSS}" $MAKE_EXTRA \
      INSTALL_MOD_PATH="$ROOT_DIR/$OUT/modules" modules_install
  tar -czf "$DIST/modules.tar.gz" -C "$OUT/modules" lib
fi

echo "== kernel build results =="
ls -l "$KERNEL_OUT"
