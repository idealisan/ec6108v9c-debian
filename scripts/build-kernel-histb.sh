#!/usr/bin/env bash
# Build hi_kernel.bin (uImage = zImage + appended DTB) and modules.tar.gz from
# the HISTB UPSTREAM: Linux 7.4-rc1 (BASE_SHA from patches/baseline) plus the
# out-of-tree quilt patch store (idealisan/hisilicon-linux-mainline, a fork of
# histb-mainline/patches).
#
# This is the plan-B pipeline (docs/030-histb-build-pipeline.md). It is
# deliberately SEPARATE from scripts/build-kernel.sh (loonpn 6.3-rc5 + our 3
# local patches), which stays on main. Nothing here touches that script.
#
# Upstream model (patches/README.md): "Kernel trees are disposable and are
# extracted from the baseline commit named in baseline; the patch files and the
# series file are the source of truth, a git branch is not."
#
# All downloads use the proxy when available (CI sets HTTP(S)_PROXY), and the
# kernel tree is fetched from GitHub by SHA - no submodule, no 6 GB fork clone.
set -eo pipefail

ROOT_DIR=$(cd "$(dirname "$0")/.." && pwd)
cd "$ROOT_DIR"

WORK=${WORK:-build/histb}
KERNEL_TREE=${KERNEL_TREE:-$WORK/linux}
PATCHES_TREE=${PATCHES_TREE:-$WORK/patches}
OUT=${OUT:-$WORK/kernel-out}
DIST=${DIST:-dist}

# Patch store (source of truth for BASE_SHA / series). Override PATCHES_REPO to
# point at the upstream histb-mainline/patches instead of the user fork.
PATCHES_REPO=${PATCHES_REPO:-https://github.com/idealisan/hisilicon-linux-mainline.git}
PATCHES_REF=${PATCHES_REF:-master}

# Kernel tree source. We fetch the exact BASE_SHA via GitHub's codeload tarball.
# BASE_SHA is read from $PATCHES_TREE/baseline after clone (single source of truth);
# KERNEL_BASE_SHA can override it for reproducible pinning.
KERNEL_TARBALL_BASE=${KERNEL_TARBALL_BASE:-https://codeload.github.com/torvalds/linux/tar.gz}

DTS=${DTS:-hisilicon/hi3798mv100-ec6108v9c}
DEFCONFIG=${DEFCONFIG:-multi_v7_defconfig}
CONFIG_FRAGMENT=${CONFIG_FRAGMENT:-configs/kernel/histb-ec6108v9c.config}
CROSS=${CROSS:-arm-linux-gnueabihf-}
MAKE_EXTRA=${MAKE_EXTRA:-}
MAKE=${MAKE:-make}
JOBS=${JOBS:-$(nproc 2>/dev/null || echo 4)}
LOADADDR=0x2000000

# Shared partition / cmdline layout (single source of truth with the flash
# package script). Not strictly needed by the kernel build itself, but sourced
# here so the DTB cmdline and p2 env cannot drift. We do NOT inject bootargs
# into the DTB: hiboot hands over ATAG cmdline via CONFIG_ARM_ATAG_DTB_COMPAT
# (see config fragment), matching the community boot method.
if [ -f "$ROOT_DIR/configs/partition-layout.env" ]; then
  set -a
  . "$ROOT_DIR/configs/partition-layout.env"
  set +a
fi

rm -rf "$KERNEL_TREE" "$PATCHES_TREE" "$OUT"
mkdir -p "$WORK" "$DIST" "$OUT"

echo "== [1/7] fetch patch store (quilt series + baseline) =="
git clone --depth 1 --branch "$PATCHES_REF" "$PATCHES_REPO" "$PATCHES_TREE"
BASELINE="$PATCHES_TREE/baseline"
KVER=$(grep -E '^KERNEL_VERSION' "$BASELINE" | awk -F':=' '{gsub(/ /,"",$2); print $2}')
SHA_FROM_BASELINE=$(grep -E '^BASE_SHA' "$BASELINE" | awk -F':=' '{gsub(/ /,"",$2); print $2}')
KERNEL_BASE_SHA=${KERNEL_BASE_SHA:-$SHA_FROM_BASELINE}
echo "  KERNEL_VERSION=$KVER  BASE_SHA=$KERNEL_BASE_SHA"
test -n "$KERNEL_BASE_SHA" || { echo "empty BASE_SHA" >&2; exit 1; }
test -f "$PATCHES_TREE/series" || { echo "series file missing" >&2; exit 1; }
test -f "$PATCHES_TREE/quilt.conf" || { echo "quilt.conf missing" >&2; exit 1; }
echo "  patches in series: $(grep -c '\.patch' "$PATCHES_TREE/series")"

echo "== [2/7] fetch disposable kernel tree at BASE_SHA =="
TARBALL="$WORK/linux-$KERNEL_BASE_SHA.tar.gz"
URL="$KERNEL_TARBALL_BASE/$KERNEL_BASE_SHA"
if command -v aria2c >/dev/null 2>&1; then
  aria2c -q -x 8 -s 8 -d "$WORK" -o "$(basename "$TARBALL")" "$URL"
else
  curl -fsSL --retry 3 -o "$TARBALL" "$URL"
fi
test -s "$TARBALL" || { echo "kernel tarball empty" >&2; exit 1; }
mkdir -p "$KERNEL_TREE"
tar -xzf "$TARBALL" -C "$KERNEL_TREE" --strip-components=1
echo "  extracted: $(du -sh "$KERNEL_TREE" | cut -f1)"

echo "== [3/7] apply quilt series (--fuzz=0, fail-fast) =="
# quilt.conf derives QUILT_PATCHES from the directory holding QUILTRC and sets
# QUILT_PC=.pc. We export QUILTRC (absolute path) and run quilt from inside the
# kernel tree, so the series and patch buckets are read from $PATCHES_TREE and
# .pc is created in the disposable tree. 'push -a' stops at the first patch
# that does not apply cleanly (--fuzz=0): a conflict means baseline and store
# have drifted and must be reconciled, not fudged.
export QUILTRC="$ROOT_DIR/$PATCHES_TREE/quilt.conf"
(
  cd "$KERNEL_TREE"
  quilt push -a
)
echo "  applied: $(cd "$KERNEL_TREE" && QUILTRC="$ROOT_DIR/$PATCHES_TREE/quilt.conf" quilt applied | wc -l) patches"

echo "== [4/7] defconfig ($DEFCONFIG) + config fragment =="
"$MAKE" -C "$KERNEL_TREE" O="$ROOT_DIR/$OUT" ARCH=arm \
  CROSS_COMPILE="${CROSS:+$CROSS}" $MAKE_EXTRA "$DEFCONFIG"
# scripts/config turns each CONFIG_X=y/m/n line into .config edits.
while IFS= read -r line; do
  case "$line" in
    CONFIG_*) ;;
    *) continue ;;
  esac
  key=${line%%=*}
  val=${line#*=}
  case "$val" in
    y) "$KERNEL_TREE/scripts/config" --file "$OUT/.config" -e "${key#CONFIG_}" ;;
    m) "$KERNEL_TREE/scripts/config" --file "$OUT/.config" -m "${key#CONFIG_}" ;;
    n) "$KERNEL_TREE/scripts/config" --file "$OUT/.config" -d "${key#CONFIG_}" ;;
    *) echo "  (skip $line)" ;;
  esac
done < "$CONFIG_FRAGMENT"
"$MAKE" -C "$KERNEL_TREE" O="$ROOT_DIR/$OUT" ARCH=arm \
  CROSS_COMPILE="${CROSS:+$CROSS}" $MAKE_EXTRA olddefconfig

echo "== [5/7] verify key options =="
grep -E "^(CONFIG_ARM_APPENDED_DTB|CONFIG_ARM_ATAG_DTB_COMPAT|CONFIG_ARCH_HISI|CONFIG_DRM=|CONFIG_DRM_HISTB_VDP2|CONFIG_DRM_SII9134|CONFIG_FRAMEBUFFER_CONSOLE|CONFIG_HISI_FEMAC|CONFIG_COMMON_CLK_HI3798|CONFIG_EXT4_FS|CONFIG_PSTORE_RAM)=" "$OUT/.config" || true

echo "== [6/7] build zImage / dtbs / modules =="
"$MAKE" -C "$KERNEL_TREE" O="$ROOT_DIR/$OUT" ARCH=arm \
  CROSS_COMPILE="${CROSS:+$CROSS}" $MAKE_EXTRA -j"$JOBS" \
  zImage dtbs modules
DTB="$OUT/arch/arm/boot/dts/$DTS.dtb"
test -f "$DTB" || { echo "DTB missing: $DTB" >&2; exit 1; }

echo "== [7/7] wrap zImage + DTB into uImage, package modules =="
KERNEL_OUT=${KERNEL_OUT:-$DIST/hi_kernel.bin}
mkdir -p "$(dirname "$KERNEL_OUT")"
cat "$OUT/arch/arm/boot/zImage" "$DTB" > "$OUT/zImage-dtb"
if command -v mkimage >/dev/null 2>&1; then
  mkimage -A arm -O linux -T kernel -C none -a $LOADADDR -e $LOADADDR \
    -n "linux-$KVER-histb" -d "$OUT/zImage-dtb" "$KERNEL_OUT"
else
  echo "  mkimage not found - writing raw zImage+DTB instead"
  cp -f "$OUT/zImage-dtb" "$KERNEL_OUT"
fi
cp -f "$OUT/zImage-dtb" "$OUT/zImage-dtb.out"

if [ "${SKIP_MODULES:-0}" = "1" ]; then
  echo "  modules skipped"
else
  "$MAKE" -C "$KERNEL_TREE" O="$ROOT_DIR/$OUT" ARCH=arm \
    CROSS_COMPILE="${CROSS:+$CROSS}" $MAKE_EXTRA \
    INSTALL_MOD_PATH="$ROOT_DIR/$OUT/modules" modules_install
  tar -czf "$DIST/modules.tar.gz" -C "$OUT/modules" lib
fi

echo "== HISTB kernel build results =="
ls -l "$KERNEL_OUT" "$OUT/arch/arm/boot/zImage" "$DTB"
