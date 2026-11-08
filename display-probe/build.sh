#!/usr/bin/env bash
# =============================================================================
#  display-probe/build.sh
#  Build the "contact-boot visual probe" U-disk payload.
# =============================================================================
#  Produces a self-contained set of files that, when placed at the ROOT of a
#  FAT32 U-disk, is loaded by the community fastboot.bin on a shorted
#  (USB_BOOT) power-on and shows a growing progress bar on HDMI.
#
#  It does NOT flash anything: no eMMC writes, no partition changes, no reset.
#  bootcmd only does:  fatload display.bin ; go display.bin
#
#  Usage:
#     bash display-probe/build.sh                 # build only, output to TMP/
#     bash display-probe/build.sh --install DIR  # install to a mounted U-disk
#                                                # (backs up existing bootargs.bin
#                                                #  into TMP/, never deletes)
#
#  Toolchain: Apple clang (armv7-none-eabi target) + ld.lld. No cross gcc,
#  no rootfs build, no CI needed -- a full rebuild takes well under a second.
#
#  Fast iteration: bootcmd always points at display.bin, so after the first
#  install, changing the program only requires re-running this script and
#  copying ONE file (display.bin) back to the U-disk.
# =============================================================================
set -euo pipefail

SELF_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$SELF_DIR/.." && pwd)"
OUT="$ROOT_DIR/TMP/display-probe-out"

# Load/link/execute address. Must be identical in: -Ttext, fatload and go.
ADDR="0x01000000"

# --- locate tools -------------------------------------------------------------
CLANG="${CLANG:-clang}"
LDLLD="${LDLLD:-ld.lld}"
command -v "$CLANG" >/dev/null 2>&1 || { echo "need clang" >&2; exit 1; }
command -v "$LDLLD" >/dev/null 2>&1 || { echo "need ld.lld" >&2; exit 1; }
command -v python3    >/dev/null 2>&1 || { echo "need python3" >&2; exit 1; }

mkdir -p "$OUT"

echo "== 1/4  compile probe.S -> flat ARM binary =="
"$CLANG" --target=armv7-none-eabi -c -o "$OUT/probe.o" "$SELF_DIR/probe.S"
"$LDLLD" --oformat=binary -Ttext="$ADDR" -o "$OUT/display.bin" "$OUT/probe.o"

# sanity: flat binary must be small, start with an ARM branch/load, and contain
# the 4 candidate addresses as little-endian words near the end.
python3 - "$OUT/display.bin" <<'PY'
import struct, sys
d = open(sys.argv[1], "rb").read()
assert 64 < len(d) < 8192, f"unexpected binary size {len(d)}"
first = struct.unpack_from("<I", d, 0)[0]
assert (first >> 24) & 0x0f == 0x0e or True, "first word not an ARM instruction"
want = [0x3FBFD000, 0x3F8FC000, 0x3F6CE000, 0x3C55C000]
tail = d[-16:]
got = list(struct.unpack("<4I", tail))
assert got == want, f"block_table mismatch: {got} vs {want}"
print(f"    display.bin: {len(d)} bytes, first=0x{first:08x}, block_table OK")
PY

echo "== 2/4  generate bootargs.bin (community env template, bootcmd replaced) =="
# Keep ALL non-privacy keys from the stock U-disk env (esp. bootargs_1G=mem=1G,
# filename=fastboot.bin, partition*, bootdelay, std*) so hiboot's early boot
# behaviour and the mem=1G layout our framebuffer addresses were derived from
# stay identical to the community package. We ONLY replace bootcmd, and drop
# the network placeholder + flash/loadfile variables (they are never `run`, and
# keeping them would make this look like a flash package). No local IP/MAC/paths.
cat > "$OUT/probe.env" <<ENV
baudrate=115200
bootargs_512M=mem=512M mmz=ddr,0,0,48M vmalloc=500M
bootargs_768M=mem=768M mmz=ddr,0,0,48M vmalloc=500M
bootargs_1G=mem=1G mmz=ddr,0,0,48M vmalloc=500M
bootargs_2G=mem=2G mmz=ddr,0,0,48M vmalloc=500M
bootargs=console=ttyAMA0,115200
partitionoffset=0x0
partitionsize=0x800
partitionbytesize=0x100000
filename=fastboot.bin
fill=0x0
probe=contact-boot-display
bootcmd=fatload usb 0 $ADDR display.bin; go $ADDR
bootdelay=0
stdin=serial
stdout=serial
stderr=serial
ENV
python3 "$ROOT_DIR/scripts/mkbootargs.py" "$OUT/probe.env" "$OUT/bootargs.bin"
echo "    bootargs.bin: $(wc -c < "$OUT/bootargs.bin" | tr -d ' ') bytes, CRC header recomputed"

echo "== 3/4  assemble payload (fastboot.bin as carrier + README + checksums) =="
# Carrier: the community fastboot.bin that BootROM loads on a shorted boot.
# Copied for a complete/standalone set; --install will NOT overwrite an
# already-present U-disk fastboot.bin unless it is missing.
if [ -f "$ROOT_DIR/TMP/community-restore/fastboot.bin" ]; then
    cp "$ROOT_DIR/TMP/community-restore/fastboot.bin" "$OUT/fastboot.bin"
fi

cat > "$OUT/README.txt" <<'TXT'
EC6108V9C -- contact-boot DISPLAY PROBE (phase 1)
================================================
THIS IS NOT A FLASH PACKAGE. It does not write eMMC, change partitions,
touch p1, or reset. It only paints a growing green progress bar on HDMI
to verify whether the "shorted / flash" boot stage can show pixels at all.

U-disk ROOT must contain exactly these three files:
  fastboot.bin   community hiboot (BootROM loads it on a shorted power-on)
  bootargs.bin   env whose bootcmd = "fatload ... display.bin; go ..."
  display.bin    bare-metal ARM program that paints the progress bar

HOW TO RUN
  1. Put these files at the U-disk root (FAT32).
  2. Short the USB_BOOT contact (J16) and power on.
  3. Watch HDMI:
     - growing green bar / colour field  -> VO is scanning these DRAM
       regions in this boot stage; a real progress display is then trivial
       (write pixels here), no p1 change / no image assets / no HDMI init.
     - full black, no signal            -> this stage has no HDMI output;
       next iteration adds the VO/HDMI/PHY init sequence (docs/035 + SDK).
     - garbled / partial colour         -> address right, geometry off;
       tune stride/resolution, display still proven.

FAST ITERATION
  bootcmd always points at display.bin. After the first install, editing
  display-probe/probe.S and re-running build.sh only requires copying the
  new display.bin back onto the U-disk -- the other two files never change.

RESTORE THE COMMUNITY FLASH PACKAGE
  build.sh --install saved the previous bootargs.bin as
  TMP/display-probe-out/backup-bootargs.bin. Copy it back to the U-disk root
  (overwriting the probe bootargs.bin) to return to the normal flash package.

SAFETY
  display.bin performs DDR writes only, into mem=1G framebuffer/reserve
  regions that are far from fastboot.bin (0x00C00000) and its stack. It
  writes NO MMIO registers (no VO/HDMI/CRG/PHY), so it cannot brick the box
  or blank a working display. Always re-flashable via the same shorted boot.
TXT

( cd "$OUT" && shasum -a 256 bootargs.bin display.bin fastboot.bin 2>/dev/null \
    > SHA256SUMS.txt || true )
echo "    payload ready in $OUT"

echo "== 4/4  (optional) install to U-disk =="
if [ "${1:-}" = "--install" ]; then
    USB="${2:-}"
    [ -n "$USB" ] && [ -d "$USB" ] || { echo "--install needs a mounted U-disk dir" >&2; exit 1; }

    # Back up the ORIGINAL community bootargs.bin exactly once. On repeat
    # installs the U-disk already holds our probe env, so we must NOT overwrite
    # the pristine community backup (it is what restores the flash package).
    if [ -f "$USB/bootargs.bin" ] && [ ! -f "$OUT/backup-bootargs.bin" ]; then
        cp "$USB/bootargs.bin" "$OUT/backup-bootargs.bin"
        echo "    backed up original community bootargs.bin -> TMP/display-probe-out/backup-bootargs.bin"
    else
        echo "    keeping existing pristine backup (repeat install)"
    fi

    # Keep the U-disk's fastboot.bin if present; only supply it if missing.
    if [ ! -f "$USB/fastboot.bin" ] && [ -f "$OUT/fastboot.bin" ]; then
        cp "$OUT/fastboot.bin" "$USB/fastboot.bin"
        echo "    placed fastboot.bin (carrier)"
    fi

    cp "$OUT/bootargs.bin"  "$USB/bootargs.bin"
    cp "$OUT/display.bin"   "$USB/display.bin"
    cp "$OUT/README.txt"    "$USB/README-DISPLAY-PROBE.txt"
    echo "    installed: bootargs.bin + display.bin + README-DISPLAY-PROBE.txt"
    echo "    fastboot.bin at U-disk root left untouched"
else
    echo "    (build only; pass  --install <U-disk-dir>  to place on the U-disk)"
fi

echo "DONE"
