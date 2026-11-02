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
SDK=$(pwd)

# SDK needs the upstream kernel tarball in third_party/open_source
OPEN_SRC="$SDK/third_party/open_source"
KTAR="$OPEN_SRC/linux-4.4.35.tar.gz"
mkdir -p "$OPEN_SRC"
valid_tar() { [ -s "$1" ] && gzip -t "$1" 2>/dev/null; }

if ! valid_tar "$KTAR"; then
  echo "== fetching linux-4.4.35.tar.gz =="
  rm -f "$KTAR"
  got=0
  for m in cdn.kernel.org/pub/linux/kernel/v4.x \
           mirrors.edge.kernel.org/pub/linux/kernel/v4.x \
           mirrors.ustc.edu.cn/kernel/v4.x \
           mirrors.tuna.tsinghua.edu.cn/kernel/v4.x; do
    echo "   trying https://$m"
    if curl -fSL --retry 3 --retry-delay 5 --max-time 1800 \
         -o "$KTAR.part" "https://$m/linux-4.4.35.tar.gz"; then
      if valid_tar "$KTAR.part"; then
        mv "$KTAR.part" "$KTAR"
        got=1
        break
      fi
      echo "   corrupt download; first bytes:"
      head -c 32 "$KTAR.part" | od -An -tx1
    fi
    rm -f "$KTAR.part"
  done
  [ "$got" = "1" ] || { echo "linux-4.4.35.tar.gz not available" >&2; exit 1; }
fi
ls -lh "$KTAR"

# Extract ourselves so we fail loudly instead of relying on the SDK's tar rule
if [ ! -d "$SDK/source/kernel/linux-4.4.y" ]; then
  echo "== extracting kernel source =="
  mkdir -p "$SDK/source/kernel"
  tar -xzf "$KTAR" -C "$SDK/source/kernel/"
  mv "$SDK/source/kernel/linux-4.4.35" "$SDK/source/kernel/linux-4.4.y"
fi

echo "== configure SDK for $BOARD =="
cp -f "configs/hi3798mv100/$BOARD"_cfg.mak ./cfg.mak
# shellcheck disable=SC1091
source ./env.sh

echo "== build prebuilts =="
make prebuilts
echo "== build hiboot =="
make hiboot
echo "== build kernel (linux 4.4) =="
# Old kernels fail on modern GCC (dtc yylloc multiple definition); -fcommon fixes it
DTC_MK="$SDK/source/kernel/linux-4.4.y/scripts/dtc/Makefile"
if [ -f "$DTC_MK" ] && ! grep -q -- '-fcommon' "$DTC_MK"; then
  sed -i 's|^\(HOSTCFLAGS_dtc-lexer.lex.o.*\)$|\1 -fcommon|' "$DTC_MK"
fi
export HOSTCFLAGS="-fcommon"
make linux -j"$JOBS"

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
