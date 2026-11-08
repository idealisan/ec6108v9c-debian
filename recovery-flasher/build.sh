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
EC6108V9C -- modified-stock-recovery AUTO FLASHER  (number + English status)
===========================================================================
Boots the STOCK Android recovery kernel (HDMI/hifb drivers included) but with
/sbin/recovery replaced by our own program. Starts automatically on power-on --
NO menu, NO key press, NO serial (the box has none).

SCREEN OUTPUT = a BIG STATE NUMBER + a short ENGLISH line under it.
  Both use a 5x7 dot-matrix font embedded in the program (digits + A-Z),
  NO external library, freestanding. Numbers are precise to report; the
  English line spells out the error. The final status stays forever (no reboot),
  so a single flash pinpoints where it stopped.

  STATE CODES (number + English shown on screen):
    1  BOOT OK                   2  MOUNT USB...
    3  USB MOUNT OK             4  MANIFEST OK
    5  FLASHING                 6  DONE NO REBOOT
    7  NO USB NODE  -> no U-disk block node ever appeared (USB not enumerated)
    8  NO MANIFEST  -> mount OK, no flash.manifest (display-only, safe)
    9  NO EMMC NODE
    70 NODE HERE MOUNT FAIL -> a node appeared but every mount combo failed
  During flashing the screen shows a growing PERCENT 0..100 + "FLASHING";
  a rising number means it is actively writing. Completion returns to 6.

U-disk ROOT must contain:
  fastboot.bin   community carrier loaded by BootROM on a shorted power-on
  bootargs.bin   env; bootcmd = fatload usb 0 0x1000000 recovery.img; bootm 0x1000000
  recovery.img   the patched Android boot.img that bootm boots
  (optional) flash.manifest  -> then it really flashes, else display-only.

ALREADY VERIFIED on real hardware:
  - shorted boot -> stock 3.10 kernel lights HDMI (original recovery UI shown);
  - patched recovery.img -> our custom userland ran (colour bar, then digit 7).
  Digit 7 last round = U-disk mount failed. This build fixes the mount to
  mirror the STOCK fs_mgr (reverse-engineered): sleep(5) first, then poll the
  device node ~12x with sleep(1), try vfat/ext4/ntfs + several node names +
  flags 0xc04. Adds a 5x7 ASCII font so the screen also prints an ENGLISH
  error line, and a split code 70 (node seen but mount failed).

WHAT THIS BUILD DOES:
  - shows state NUMBER + English one-liner; HOLDS the final status on screen;
  - U-disk mount mirrors stock fs_mgr: wait for enumeration, many candidates;
  - best-effort writes /usb/flasher.log (fsync+sync) -- if the U-disk mounts;
  - IF /usb/flash.manifest exists: flashes each item to raw /dev/block/mmcblk0
    by absolute LBA, decoding Android sparse images (R=raw, S=sparse).
    NO manifest => ZERO eMMC writes.
  - flash.manifest line format:  <src-full-path> <lba-hex> <bytes-hex> <R|S>
    (bytes ignored for sparse). Completion = 6, never reboots.

HOW TO REPORT: say the NUMBER and/or the English line you see. Most likely:
  - 7  "NO USB NODE"        = no U-disk node appeared (USB not enumerated);
  - 70 "NODE HERE MOUNT FAIL" = node appeared but all mount combos failed;
  - 8  "NO MANIFEST"        = mount OK, no manifest yet (ready to flash);
  - 6  "DONE NO REBOOT"     = a manifest was present and flashing completed.

SAFETY:
  - Without flash.manifest: ZERO eMMC writes (pure display/diagnostic).
  - The stock 3.10 kernel is kept BYTE-FOR-BYTE; only the ramdisk userland file
    sbin/recovery is replaced.
  - Sparse DONT_CARE chunks are skipped (no zeroing of unrelated sectors).
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
