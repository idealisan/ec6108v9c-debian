#!/usr/bin/env bash
# Build hiboot (fastboot-burn.bin) and the Linux 4.4 kernel (hi_kernel.bin)
# from the HiSTB SDK, replacing the images extracted from the community package.
set -eo pipefail

SDK=${SDK:-build/sdk}
DIST=${DIST:-dist}
BOARD=${BOARD:-hi3798mdmo1g_hi3798mv100}
JOBS=${JOBS:-$(nproc 2>/dev/null || echo 4)}

ROOT_DIR=$(cd "$(dirname "$0")/.." && pwd)
cd "$ROOT_DIR"

if [ ! -f "$SDK/Makefile" ]; then
  bash scripts/fetch-sdk.sh >/dev/null
fi

mkdir -p "$DIST"

cd "$SDK"

echo "== configure SDK for $BOARD =="
cp -f "configs/hi3798mv100/$BOARD"_cfg.mak ./cfg.mak
# shellcheck disable=SC1091
source ./env.sh

echo "== build prebuilts + hiboot + kernel =="
make prebuilts hiboot linux -j"$JOBS"

echo "== locate SDK outputs =="
FB=$(find out -type f -name 'fastboot-burn.bin' | head -1)
UIMG=$(find out -type f -path '*arch/arm/boot/uImage' | head -1)
[ -n "$UIMG" ] || UIMG=$(find out -type f -name 'hi_kernel.bin' | head -1)
BA=$(find out -type f -name 'bootargs.bin' | head -1)
echo "hiboot:  $FB"
echo "kernel:  $UIMG"
echo "bootargs:$BA"

[ -n "$FB" ] || { echo "fastboot-burn.bin not found" >&2; exit 1; }
[ -n "$UIMG" ] || { echo "kernel image not found" >&2; exit 1; }

cp -f "$FB" "$ROOT_DIR/$DIST/fastboot-burn.bin"
cp -f "$UIMG" "$ROOT_DIR/$DIST/hi_kernel.bin"
[ -n "$BA" ] && cp -f "$BA" "$ROOT_DIR/$DIST/bootargs-sdk.bin"

echo "== results =="
ls -l "$ROOT_DIR/$DIST/fastboot-burn.bin" "$ROOT_DIR/$DIST/hi_kernel.bin"
