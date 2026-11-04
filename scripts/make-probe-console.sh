#!/usr/bin/env bash
# Build the "screen probe": stock p11 kernel + our tiny initramfs, wrapped in an
# Android boot.img so hiboot's bootm can load both from a U-disk.
#
#   KERNEL=/path/to/p11_kernel.img  (or a bare zImage) bash scripts/make-probe-console.sh
#
# The env written to the stick only does fatload + bootm: nothing is written to
# the eMMC, p1 (hiboot) is never touched.
set -eo pipefail

KERNEL=${KERNEL:-}
DIST=${DIST:-dist}
STAMP=${STAMP:-$(date -u +%Y%m%dT%H%M%SZ)}
OUT=${OUT:-$DIST/probe-console}

ROOT_DIR=$(cd "$(dirname "$0")/.." && pwd)
cd "$ROOT_DIR"

[ -n "$KERNEL" ] || { echo "set KERNEL=<p11_kernel.img or zImage>" >&2; exit 1; }
[ -f "$KERNEL" ] || { echo "no such file: $KERNEL" >&2; exit 1; }

WORK=build/probe-console
mkdir -p "$WORK" "$OUT"

# --- kernel: accept a full boot.img (extract zImage) or a bare zImage --------
if [ "$(head -c 8 "$KERNEL")" = "ANDROID!" ]; then
  python3 - "$KERNEL" "$WORK/zImage" <<'PY'
import struct, sys
d = open(sys.argv[1], 'rb').read()
ksize, kaddr, rsize, raddr, ssize, saddr, taddr, page = struct.unpack_from('<8I', d, 8)
open(sys.argv[2], 'wb').write(d[page:page + ksize])
print('extracted zImage: %d bytes (load 0x%08x)' % (ksize, kaddr))
PY
else
  cp -f "$KERNEL" "$WORK/zImage"
fi

# --- initramfs: freestanding /init, no libc ---------------------------------
CC=${CC:-}
if [ -z "$CC" ]; then
  if command -v clang >/dev/null; then
    CC="clang -target armv7a-linux-gnueabihf -march=armv7-a -mfloat-abi=soft -fuse-ld=lld"
  elif command -v arm-linux-gnueabihf-gcc >/dev/null; then
    CC=arm-linux-gnueabihf-gcc
  else
    echo "need clang or arm-linux-gnueabihf-gcc" >&2; exit 1
  fi
fi
$CC -nostdlib -static -fno-builtin -O2 -Wl,-e,_start -o "$WORK/init" probe/init.c
python3 probe/mkcpio.py "$WORK/init" "$WORK/ramdisk.gz"

# --- boot.img ---------------------------------------------------------------
CMDLINE=${CMDLINE:-mem=1G mmz=ddr,0,0,400M coherent_pool=2M console=ttyAMA0,115200 blkdevparts=mmcblk0:1M(fastboot),4M(bootargs),16M(recovery),1M(deviceinfo),4M(baseparam),4M(pqparam),4M(logo),16M(fastplay),8M(misc),24M(factory),12M(kernel),8M(iptv_data),340M(backup),340M(cache),520M(system),-(userdata)}
python3 scripts/mk-android-bootimg.py "$WORK/zImage" "$OUT/boot.img" \
  --ramdisk "$WORK/ramdisk.gz" --cmdline "$CMDLINE" --name "linux-probe"

# --- hiboot environment -----------------------------------------------------
cat > "$WORK/probe.env" <<EOF
baudrate=115200
bootdelay=0
stdin=serial
stdout=serial
stderr=serial
bootargs=$CMDLINE
bootcmd=fatload usb 0 0x02000000 boot.img; bootm 0x02000000
EOF
python3 scripts/mkbootargs.py "$WORK/probe.env" "$OUT/bootargs.bin"

echo "== $OUT"
ls -l "$OUT"
