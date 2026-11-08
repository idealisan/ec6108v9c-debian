#!/usr/bin/env bash
# =============================================================================
#  recovery-flasher/build.sh
#  Build the "modified stock recovery" auto-flasher U-disk payload.
# =============================================================================
#  WHAT IT BUILDS
#  A U-disk ROOT payload that, on a shorted USB_BOOT power-on, boots the STOCK
#  Android recovery 3.10 kernel (which owns the HDMI/VO/hifb drivers) with a
#  ramdisk whose /sbin/recovery is replaced by our own auto-flash program.
#  The program starts automatically (no menu/key/serial), draws a progress bar
#  on /dev/graphics/fb0, and flashes images listed in /usb/flash.manifest.
#
#  KEY FACT (verified by teammate, docs/050): this vendor `bootm` boots an
#  Android boot.img DIRECTLY -- no uImage conversion, no separate ramdisk,
#  no DTB. `check_header` only memcmp's "ANDROID!" (8 bytes); `get_ramdisk`
#  memcpy's the ramdisk to 0x04e00000 and passes it as initrd. So bootcmd is:
#      fatload usb 0 0x1000000 recovery.img; bootm 0x1000000
#
#  TOOLCHAIN: Apple clang (armv7-unknown-linux-gnueabihf) + ld.lld. No cross
#  gcc, no libc, no sysroot, no CI. Full rebuild takes well under a second.
#
#  Usage:
#     bash recovery-flasher/build.sh                    # build to TMP/ only
#     bash recovery-flasher/build.sh --verify          # put UNMODIFIED recovery
#                                                     # as recovery.img (go/no-go)
#     bash recovery-flasher/build.sh --install DIR    # install to a mounted U-disk
#     bash recovery-flasher/build.sh --verify --install DIR
# =============================================================================
set -euo pipefail

SELF_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$SELF_DIR/.." && pwd)"
OUT="$ROOT_DIR/TMP/recovery-flash-out"
# The stock recovery boot.img lives IN the repo (repack.py reads it); the
# 16 MiB partition dump is only an optional fallback, no longer required.
STOCK_IMG="$ROOT_DIR/recovery-flasher/stock/recovery-stock.img"
COMMUNITY_FB="$ROOT_DIR/TMP/community-restore/fastboot.bin"

CLANG="${CLANG:-clang}"
command -v "$CLANG"   >/dev/null 2>&1 || { echo "need clang" >&2; exit 1; }
command -v ld.lld     >/dev/null 2>&1 || { echo "need ld.lld" >&2; exit 1; }
command -v python3    >/dev/null 2>&1 || { echo "need python3" >&2; exit 1; }
[ -f "$STOCK_IMG" ] || { echo "missing $STOCK_IMG (stock recovery boot.img)" >&2; exit 1; }

MODE="flash"
USB=""
prev=""
for arg in "$@"; do
    [ "$arg" = "--verify" ] && MODE="verify"
    [ "$prev" = "--install" ] && USB="$arg"
    prev="$arg"
done

mkdir -p "$OUT"

echo "== 1/4  compile flasher (ARM Linux static ELF) =="
# armv7 32-bit, soft-float, NO auto-vectorization: the stock 3.10 recovery
# kernel may not enable VFP/NEON (CP10/CP11) for early userspace, so a single
# NEON instruction from -O2 vectorization would trap. Keep it pure integer ARM.
"$CLANG" --target=armv7-unknown-linux-gnueabi -fuse-ld=lld \
    -static -nostdlib -ffreestanding -fno-builtin -fno-stack-protector \
    -fno-vectorize -fno-slp-vectorize -mfloat-abi=soft \
    -O2 -Wall -Wextra -o "$OUT/flasher" "$SELF_DIR/flasher.c"
file "$OUT/flasher"
python3 - "$OUT/flasher" <<'PY'
import sys, struct
d=open(sys.argv[1],"rb").read()
assert d[:4]==b"\x7fELF" and d[4]==1 and d[5]==1, "not ELF32 LE"
assert struct.unpack_from("<H",d,18)[0]==0x28, "not ARM"
assert struct.unpack_from("<H",d,16)[0]==2, "not EXEC"
assert d.count(b"\x00\x00\x00\xef")>0, "no svc #0 syscall"
print(f"    flasher: {len(d)} B, ELF32 ARM static EXEC, syscall svc present")
PY

echo "== 2/4  repack: replace sbin/recovery, keep stock kernel byte-for-byte =="
python3 "$SELF_DIR/repack.py"

echo "== 3/4  generate bootargs.bin (bootm directly boots the ANDROID! img) =="
# Community env template, keeping all non-privacy keys (bootargs_*, filename,
# partition*, bootdelay, std*). Only bootcmd + bootargs change.
cat > "$OUT/flash.env" <<'ENV'
baudrate=115200
bootargs_512M=mem=512M mmz=ddr,0,0,48M vmalloc=500M
bootargs_768M=mem=768M mmz=ddr,0,0,48M vmalloc=500M
bootargs_1G=mem=1G mmz=ddr,0,0,48M vmalloc=500M
bootargs_2G=mem=2G mmz=ddr,0,0,48M vmalloc=500M
bootargs=console=ttyAMA0,115200 root=/dev/ram rw init=/init mem=1G mmz=ddr,0,0,256M
partitionoffset=0x0
partitionsize=0x800
partitionbytesize=0x100000
filename=fastboot.bin
fill=0x0
verify=n
probe=recovery-auto-flasher
bootcmd=fatload usb 0 0x1000000 recovery.img; bootm 0x1000000
bootdelay=0
stdin=serial
stdout=serial
stderr=serial
ENV
python3 "$ROOT_DIR/scripts/mkbootargs.py" "$OUT/flash.env" "$OUT/bootargs.bin"
echo "    bootargs.bin CRC recomputed; bootcmd = fatload ... recovery.img; bootm"

echo "== 4/4  assemble U-disk payload =="
# recovery.img is whatever bootm loads. --verify selects the pristine stock
# image (go/no-go HDMI check); default selects our patched auto-flasher.
if [ "$MODE" = "verify" ]; then
    cp "$OUT/recovery-verify.img" "$OUT/recovery.img"
    echo "    MODE=verify : recovery.img = UNMODIFIED stock (proves kernel HDMI)"
else
    cp "$OUT/recovery-flash-boot.img" "$OUT/recovery.img"
    echo "    MODE=flash  : recovery.img = patched auto-flasher"
fi
[ -f "$COMMUNITY_FB" ] && cp "$COMMUNITY_FB" "$OUT/fastboot.bin"

cat > "$OUT/README.txt" <<'TXT'
EC6108V9C -- modified-stock-recovery AUTO FLASHER
=================================================
Boots the STOCK Android recovery kernel (HDMI/hifb drivers included) but with
/sbin/recovery replaced by our own program. Starts automatically on power-on --
NO menu, NO key press, NO serial (the box has none).

U-disk ROOT must contain:
  fastboot.bin   community carrier loaded by BootROM on a shorted power-on
  bootargs.bin   env; bootcmd = fatload usb 0 0x1000000 recovery.img; bootm 0x1000000
  recovery.img   the (patched or verify) Android boot.img that bootm boots

TWO-STAGE GO/NO-GO (important -- do this first):
  1. Put the UNMODIFIED image as recovery.img (build.sh --verify). Short the
     USB_BOOT contact, power on. If the ORIGINAL recovery UI appears, the stock
     kernel lights HDMI in the flash branch -> this whole approach is valid.
     If it stays black, the kernel does NOT init HDMI from zero -> both the
     recovery and bare-metal routes fail; stop and rethink.
  2. If step 1 shows a picture, use the PATCHED image (build.sh default) as
     recovery.img. Our program then draws a progress bar and auto-flashes.

AUTO-FLASH (no interaction):
  Program mounts the U-disk at /usb and, IF /usb/flash.manifest exists, flashes
  each line:  <src-full-path> <dest-LBA-hex> <byte-count-hex>
  writing <src> into /dev/block/mmcblk0 at LBA <dest>, updating the bar per
  item. NO manifest => NO eMMC writes (pure, harmless display demo). Writes go
  to the RAW block device by absolute LBA, so partition-table mismatches
  (stock 16-partition cmdline vs community 9-partition eMMC) do not matter.
  Example manifest line (paths are full paths as seen in recovery userspace):
      /usb/mv100/hi_kernel.bin 7000 200000

SAFETY:
  - The stock 3.10 kernel is kept BYTE-FOR-BYTE; only the ramdisk userland file
    sbin/recovery is replaced. No eMMC writes unless flash.manifest is present.
  - Always re-flashable via the same shorted U-disk flow (p1/fastboot untouched).
TXT

# checksums (excluding the sha file itself)
( cd "$OUT" && shasum -a 256 bootargs.bin recovery.img recovery-verify.img \
    recovery-flash-boot.img flasher fastboot.bin 2>/dev/null > SHA256SUMS.txt || true )
echo "    payload ready in $OUT"

if [ -n "$USB" ]; then
    [ -d "$USB" ] || { echo "--install needs a mounted U-disk dir" >&2; exit 1; }
    # Back up existing bootargs.bin exactly once (never delete anything).
    if [ -f "$USB/bootargs.bin" ] && [ ! -f "$OUT/backup-bootargs.bin" ]; then
        cp "$USB/bootargs.bin" "$OUT/backup-bootargs.bin"
        echo "    backed up original U-disk bootargs.bin -> backup-bootargs.bin"
    fi
    if [ ! -f "$USB/fastboot.bin" ] && [ -f "$OUT/fastboot.bin" ]; then
        cp "$OUT/fastboot.bin" "$USB/fastboot.bin"
    fi
    cp "$OUT/bootargs.bin"  "$USB/bootargs.bin"
    cp "$OUT/recovery.img"  "$USB/recovery.img"
    cp "$OUT/README.txt"    "$USB/README-RECOVERY-FLASHER.txt"
    echo "    installed to $USB : bootargs.bin + recovery.img + README"
    echo "    fastboot.bin left untouched"
fi

echo "DONE"
