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

OUT="out/hi3798mv100"
echo "== SDK outputs =="
find "$OUT" -maxdepth 2 -type f \( -name '*.bin' -o -name '*.img' \) | head -30

cp -f "$OUT/fastboot-burn.bin" "$ROOT_DIR/$DIST/fastboot-burn.bin"
cp -f "$OUT/hi_kernel.bin" "$ROOT_DIR/$DIST/hi_kernel.bin"
if [ -f "$OUT/bootargs.bin" ]; then
  cp -f "$OUT/bootargs.bin" "$ROOT_DIR/$DIST/bootargs-sdk.bin"
fi

echo "== results =="
ls -l "$ROOT_DIR/$DIST/fastboot-burn.bin" "$ROOT_DIR/$DIST/hi_kernel.bin"
