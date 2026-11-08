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

# Kernel tree source = the upstream kernel git repository, shallow-cloned at the
# baseline tag. This is the "clone the repo, then apply patches" flow the patch
# store README prescribes; it replaces the codeload tarball, which GitHub
# rate-limits (HTTP 429 on shared CI egress). The tag (v<KERNEL_VERSION>) is
# derived from $PATCHES_TREE/baseline and can be overridden via KERNEL_REF.
KERNEL_GIT=${KERNEL_GIT:-https://github.com/torvalds/linux.git}

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
# baseline gives a short SHA. We clone by TAG (always advertised, --depth 1
# dereferences the annotated tag to the commit) and then verify HEAD starts
# with the baseline short SHA. Fetching a short SHA directly does NOT work
# ("couldn't find remote ref"), and fetching a full SHA is unreliable on large
# repos; the tag is the canonical, robust handle.
KERNEL_REF=${KERNEL_REF:-v$KVER}
echo "  KERNEL_VERSION=$KVER  BASE_SHA=$SHA_FROM_BASELINE  ref=$KERNEL_REF"
test -n "$SHA_FROM_BASELINE" || { echo "empty BASE_SHA in baseline" >&2; exit 1; }
test -f "$PATCHES_TREE/series" || { echo "series file missing" >&2; exit 1; }
test -f "$PATCHES_TREE/quilt.conf" || { echo "quilt.conf missing" >&2; exit 1; }
echo "  patches in series: $(grep -c '\.patch' "$PATCHES_TREE/series")"

echo "== [2/7] clone kernel tree at baseline tag =="
# Clone the upstream kernel repo shallowly at the baseline tag. This is the
# canonical "clone the repo, then apply patches" flow the patch store README
# prescribes (git archive BASE_SHA). git smart-HTTP is NOT subject to the
# codeload tarball rate limit (HTTP 429) that killed both previous runs, and
# --depth 1 --branch <tag> pulls only one commit, dereferencing any annotated
# tag to its commit automatically.
git clone -q --depth 1 --branch "$KERNEL_REF" --single-branch \
  "$KERNEL_GIT" "$KERNEL_TREE"
HEAD_SHA=$(git -C "$KERNEL_TREE" rev-parse HEAD)
echo "  HEAD=$HEAD_SHA (baseline $KERNEL_REF -> $SHA_FROM_BASELINE)"
case "$HEAD_SHA" in
  "$SHA_FROM_BASELINE"*) ;;
  *) echo "kernel HEAD does not match baseline BASE_SHA (tag drifted?)" >&2; exit 1 ;;
esac
echo "  checked out: $(du -sh "$KERNEL_TREE" | cut -f1)"

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
