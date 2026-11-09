#!/usr/bin/env bash
# Build hi_kernel.bin (uImage = zImage + appended DTB) and modules.tar.gz for
# EC6108V9C from the pinned loonpn/ec6108v9c-linux-kernel submodule, with our
# local patches applied (simple-framebuffer, Tsensor, rtl8xxxu support).
set -eo pipefail

KERNEL_SRC=${KERNEL_SRC:-third_party/linux-hi3798mv100}
OUT=${OUT:-build/kernel}
DIST=${DIST:-dist}
CROSS=${CROSS:-arm-linux-gnueabihf-}
# Extra make variables, e.g. MAKE_EXTRA="LLVM=1 LLVM_PREFIX=/path/to/llvm/"
# to cross compile with clang instead of gcc (handy on a local Mac).
MAKE_EXTRA=${MAKE_EXTRA:-}
# GNU make >= 3.82 is required; macOS ships 3.81, so allow an override
# (e.g. MAKE=gmake).
MAKE=${MAKE:-make}
DTS=${DTS:-hi3798mv100-ec6108v9c}
JOBS=${JOBS:-$(nproc 2>/dev/null || echo 4)}
LOADADDR=0x2000000
# Framebuffer left by hiboot. Leave empty (node disabled) until the physical
# address is confirmed from the boot log; set FB_BASE=0x3xxxxxxx to enable HDMI
# console. CI exposes this as a workflow_dispatch input.
FB_BASE=${FB_BASE:-}
# Geometry measured on the community system (docs/040): 1920x1080 ARGB8888,
# stride 7680, and a DOUBLE-BUFFERED scan-out region (2 x 1080p = 0xFD0000 B).
# FB_SIZE covers both frames so the reserved-memory / simplefb node spans the
# whole region VO scans; fbcon still uses a single 1080p frame via pdata.height.
FB_WIDTH=${FB_WIDTH:-1920}
FB_HEIGHT=${FB_HEIGHT:-1080}
FB_STRIDE=${FB_STRIDE:-7680}
FB_FORMAT=${FB_FORMAT:-a8r8g8b8}
FB_SIZE=${FB_SIZE:-0x1000000}
export FB_WIDTH FB_HEIGHT FB_STRIDE FB_FORMAT FB_SIZE
PATCH_DIR=${PATCH_DIR:-patches/kernel}
CONFIG_FRAGMENT=${CONFIG_FRAGMENT:-configs/kernel/ec6108v9c.config}
# Display driver scheme (docs/052):
#   "simplefb"        = legacy mainline simplefb handoff (DEFAULT; keeps the
#                       existing CI path byte-for-byte unchanged).
#   "vendor-backport" = 6.3 mainline kernel + backported HiSilicon private
#                       VO/HDMI/hifb display stack. User wants mainline KERNEL
#                       features but does NOT require mainline drivers.
# The wired NIC (hisi_femac) is shared by both schemes and is NOT switched here.
# The vendor branch fail-fasts until its driver is ready (see PORTING.md).
DISPLAY_DRIVER=${DISPLAY_DRIVER:-simplefb}

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
# Patches that are already applied (local iteration) are skipped instead of
# failing the whole build. The touched files are restored first, because a
# previous local run may have left placeholder substitutions in the DTS.
git -C "$KERNEL_SRC" checkout -- arch/arm/boot/dts/hi3798mv100-ec6108v9c.dts \
    drivers/thermal/Kconfig drivers/thermal/Makefile \
    drivers/video/fbdev/Kconfig drivers/video/fbdev/Makefile 2>/dev/null || true
for p in "$PATCH_DIR/0001-ec6108v9c-dts-simplefb-tsensor.patch" \
         "$PATCH_DIR/0002-thermal-kconfig-makefile.patch" \
         "$PATCH_DIR/0003-hdmi-console-kconfig-makefile.patch"; do
  if git -C "$KERNEL_SRC" apply --check "$ROOT_DIR/$p" 2>/dev/null; then
    git -C "$KERNEL_SRC" apply "$ROOT_DIR/$p"
    echo "  applied: $(basename "$p")"
  elif git -C "$KERNEL_SRC" apply --reverse --check "$ROOT_DIR/$p" 2>/dev/null; then
    echo "  already applied: $(basename "$p")"
  else
    echo "  cannot apply: $(basename "$p")" >&2
    exit 1
  fi
done
cp "$PATCH_DIR/hi3798mv100_tsensor.c" "$KERNEL_SRC/drivers/thermal/"
cp "$PATCH_DIR/hi3798mv100-hdmi-console.c" "$KERNEL_SRC/drivers/video/fbdev/"

# ---- display driver scheme (docs/052) --------------------------------------
# "simplefb" (default) keeps the legacy handoff above unchanged.
# "vendor-backport" is the new direction: 6.3 mainline kernel + backported
# HiSilicon private VO/HDMI/hifb stack. It needs the register-init sequence
# from the full disassembly (TMP/stock-rom-research/full-disasm/, in progress).
# Until patches/vendor-display/ ships the driver, fail fast instead of
# pretending the build is the vendor one. The simplefb default never breaks.
# vendor-display/ lives directly under patches/, NOT under PATCH_DIR
# (patches/kernel/). Keep it independent so the two paths cannot drift.
VD_DIR=${VD_DIR:-patches/vendor-display}
if [ "$DISPLAY_DRIVER" = "vendor-backport" ]; then
  echo "== display scheme: vendor-backport (docs/052) =="
  if [ ! -f "$VD_DIR/hi3798mv100_vendor_display.c" ] || \
     [ ! -f "$VD_DIR/0004-vendor-display-kconfig-makefile.patch" ]; then
    echo "ERROR: vendor-display driver not ready." >&2
    echo "  Need hi3798mv100_vendor_display.c + 0004-...patch in $VD_DIR." >&2
    echo "  Register-init sequence comes from the full disassembly" >&2
    echo "  (TMP/stock-rom-research/full-disasm/), see $VD_DIR/PORTING.md and docs/052." >&2
    exit 1
  fi
  VD_PATCH="$VD_DIR/0004-vendor-display-kconfig-makefile.patch"
  # Same three-way check as 0001-0003 above: apply / already-applied / hard
  # error. A silent "check failed -> skip" would leave Kconfig+Makefile
  # unpatched while the .c is still copied, producing a kernel that builds
  # but never compiles the vendor driver in -- exactly the "pretend done"
  # failure docs/052 §3 forbids.
  if git -C "$KERNEL_SRC" apply --check "$ROOT_DIR/$VD_PATCH" 2>/dev/null; then
    git -C "$KERNEL_SRC" apply "$ROOT_DIR/$VD_PATCH"
    echo "  applied: 0004-vendor-display-kconfig-makefile.patch"
  elif git -C "$KERNEL_SRC" apply --reverse --check "$ROOT_DIR/$VD_PATCH" 2>/dev/null; then
    echo "  already applied: 0004-vendor-display-kconfig-makefile.patch"
  else
    echo "ERROR: cannot apply 0004-vendor-display-kconfig-makefile.patch" >&2
    echo "  Generate it against the tree AFTER 0001-0003 (fbdev Kconfig/Makefile)." >&2
    echo "  See patches/vendor-display/PORTING.md and docs/052." >&2
    exit 1
  fi
  cp "$VD_DIR/hi3798mv100_vendor_display.c" "$KERNEL_SRC/drivers/video/fbdev/"
  # Vendor stack initialises VO/HDMI itself; no simplefb / fb_base handoff.
  FB_BASE=""
fi

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
"$MAKE" -C "$KERNEL_SRC" O="$ROOT_DIR/$OUT" ARCH=arm CROSS_COMPILE="${CROSS:+$CROSS}" $MAKE_EXTRA \
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
    # Quoted string value, e.g. CONFIG_NLS_DEFAULT="utf8". The old pattern
    # "*" matched a LITERAL asterisk, so every string option was silently
    # skipped by the fall-through below -- a real (if minor) config-loss bug.
    \"*\") "$KERNEL_SRC/scripts/config" --file "$OUT/.config" --set-str "${key#CONFIG_}" "${val//\"/}" ;;
    *) echo "  (skip $line)" ;;
  esac
done < "$CONFIG_FRAGMENT"
"$MAKE" -C "$KERNEL_SRC" O="$ROOT_DIR/$OUT" ARCH=arm CROSS_COMPILE="${CROSS:+$CROSS}" $MAKE_EXTRA olddefconfig
echo "== kernel: verify key options =="
# The wired MAC is included here on purpose: if any of these ever reads
# "is not set", eth0 is never created and the box boots with no IP at all.
grep -E "^(CONFIG_RTL8XXXU|CONFIG_FB_SIMPLE|CONFIG_FRAMEBUFFER_CONSOLE|CONFIG_THERMAL=|CONFIG_HI3798MV100_TSENSOR|CONFIG_EXT4_FS|CONFIG_BTRFS_FS|CONFIG_NTFS3_FS|CONFIG_EXFAT_FS|CONFIG_USB_HID|CONFIG_NETDEVICES|CONFIG_NET_VENDOR_HISILICON|CONFIG_HISI_FEMAC|CONFIG_MDIO_HISI_FEMAC|CONFIG_PHYLIB|CONFIG_COMMON_CLK_HI3798|CONFIG_RESET_HISI)=" "$OUT/.config"

echo "== kernel: build zImage / dtbs / modules =="
"$MAKE" -C "$KERNEL_SRC" O="$ROOT_DIR/$OUT" ARCH=arm CROSS_COMPILE="${CROSS:+$CROSS}" $MAKE_EXTRA \
    -j"$JOBS" zImage dtbs modules

echo "== kernel: wrap zImage + DTB into uImage =="
# KERNEL_OUT lets a second build (e.g. the diagnostic community-layout
# kernel) write to its own file instead of overwriting the shipped one.
KERNEL_OUT=${KERNEL_OUT:-$DIST/hi_kernel.bin}
mkdir -p "$(dirname "$KERNEL_OUT")"
cat "$OUT/arch/arm/boot/zImage" "$OUT/arch/arm/boot/dts/$DTS.dtb" > "$OUT/zImage-dtb"
if command -v mkimage >/dev/null 2>&1; then
  mkimage -A arm -O linux -T kernel -C none -a $LOADADDR -e $LOADADDR \
      -n "linux-hi3798mv100" -d "$OUT/zImage-dtb" "$KERNEL_OUT"
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
