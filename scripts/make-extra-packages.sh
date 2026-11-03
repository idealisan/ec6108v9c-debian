#!/usr/bin/env bash
# Build two small helper packages:
#   probe  - bootargs.bin that only resets, proving the stock hiboot consumes
#            the U-disk environment (no writes at all)
#   restore- bootargs.bin that writes the stock backups back to their original
#            offsets (files come from the backup stick itself)
set -eo pipefail

DIST=${DIST:-dist}
STAMP=${STAMP:-$(date -u +%Y%m%dT%H%M%SZ)}

ROOT_DIR=$(cd "$(dirname "$0")/.." && pwd)
cd "$ROOT_DIR"
mkdir -p "$DIST" build/extra

# ---------------- probe ----------------
P=build/extra/probe
rm -rf "$P"; mkdir -p "$P"
cat > "$P/probe.env" <<EOF
baudrate=115200
bootcmd=reset
bootdelay=0
stdin=serial
stdout=serial
stderr=serial
EOF
python3 scripts/mkbootargs.py "$P/probe.env" "$P/bootargs.bin"
cat > "$P/README.txt" <<EOF
EC6108V9C hiboot U-disk probe (no writes)
built (UTC): $STAMP

Purpose: verify that the box's hiboot really reads and executes bootargs.bin
from the USB stick, WITHOUT touching the eMMC.

How to test:
  1. Copy bootargs.bin to the root of a FAT32 stick.
  2. Power off, insert the stick, power on while holding the recovery key.
  3. If the box reboots immediately / keeps rebooting while the stick is
     inserted, the stock hiboot DID consume our environment.
     Remove the stick and power-cycle: it should boot Android normally.
  4. If the box boots Android as usual, the hiboot ignored the stick
     (wrong key/timing or a different upgrade path) - do NOT flash.

Nothing is written to eMMC by this package.
EOF
( cd "$P" && zip -q "mv100-mdmo1g-probe-$STAMP.zip" bootargs.bin README.txt )
mv "$P/mv100-mdmo1g-probe-$STAMP.zip" "$DIST/"

# ---------------- restore ----------------
R=build/extra/restore
rm -rf "$R"; mkdir -p "$R"
# offsets/counts in 512-byte sectors (factory layout)
cat > "$R/restore.env" <<EOF
baudrate=115200
bootdelay=0
stdin=serial
stdout=serial
stderr=serial
load2=fatload usb 0 0x1000000 backup/p02_bootargs.img
load3=fatload usb 0 0x1000000 backup/p03_recovery.img
load4=fatload usb 0 0x1000000 backup/p04_deviceinfo.img
load5=fatload usb 0 0x1000000 backup/p05_baseparam.img
load6=fatload usb 0 0x1000000 backup/p06_pqparam.img
load7=fatload usb 0 0x1000000 backup/p07_logo.img
load8=fatload usb 0 0x1000000 backup/p08_fastplay.img
load9=fatload usb 0 0x1000000 backup/p09_misc.img
load10=fatload usb 0 0x1000000 backup/p10_factory.img
load11=fatload usb 0 0x1000000 backup/p11_kernel.img
load12=fatload usb 0 0x1000000 backup/p12_iptv_data.img
load13=fatload usb 0 0x1000000 backup/p13_backup.img
load14=fatload usb 0 0x1000000 backup/p14_cache.img
load15=fatload usb 0 0x1000000 backup/p15_system.img
load1=fatload usb 0 0x1000000 backup/p01_fastboot.img
f2=mmc write 0 0x1000000 0x800 0x2000
f3=mmc write 0 0x1000000 0x2800 0x8000
f4=mmc write 0 0x1000000 0xA800 0x800
f5=mmc write 0 0x1000000 0xB000 0x2000
f6=mmc write 0 0x1000000 0xD000 0x2000
f7=mmc write 0 0x1000000 0xF000 0x2000
f8=mmc write 0 0x1000000 0x11000 0x8000
f9=mmc write 0 0x1000000 0x19000 0x4000
f10=mmc write 0 0x1000000 0x1D000 0xC000
f11=mmc write 0 0x1000000 0x29000 0x6000
f12=mmc write 0 0x1000000 0x2F000 0x4000
f13=mmc write 0 0x1000000 0x33000 0xAA000
f14=mmc write 0 0x1000000 0xDD000 0xAA000
f15=mmc write 0 0x1000000 0x187000 0x104000
f1=mmc write 0 0x1000000 0x0 0x800
r2=run load2 f2
r3=run load3 f3
r4=run load4 f4
r5=run load5 f5
r6=run load6 f6
r7=run load7 f7
r8=run load8 f8
r9=run load9 f9
r10=run load10 f10
r11=run load11 f11
r12=run load12 f12
r13=run load13 f13
r14=run load14 f14
r15=run load15 f15
r1=run load1 f1
bootcmd=run r2; run r3; run r4; run r5; run r6; run r7; run r8; run r9; run r10; run r11; run r12; run r13; run r14; run r15; run r1; reset
EOF
python3 scripts/mkbootargs.py "$R/restore.env" "$R/bootargs.bin"
cat > "$R/README.txt" <<EOF
EC6108V9C stock restore package
built (UTC): $STAMP

Restores the factory partition images written by our backup (p01-p15) back to
their original offsets, then reboots into the original Android system.

Requirements:
  - the USB stick already contains the backup folder created on the box:
        backup/p01_fastboot.img   backup/p02_bootargs.img  ...
        backup/p15_system.img
  - bootargs.bin from THIS zip at the stick root (next to backup/)

Order: p2,p3,...,p15 are written first and p1 (fastboot) LAST, so a partial run
never leaves the box without a bootloader.

Not covered: p16 userdata (6 GB, cannot be loaded into 1 GB DDR by hiboot).
After the restore the box will boot with a fresh/blank userdata - Android will
re-initialise /data. To also restore userdata, boot Debian (if still working)
and dd the three chunk files back:
    dd if=p16_userdata_a.img of=/dev/mmcblk0p16 bs=1M
    dd if=p16_userdata_b.img of=/dev/mmcblk0p16 bs=1M seek=2048
    dd if=p16_userdata_c.img of=/dev/mmcblk0p16 bs=1M seek=4096
EOF
( cd "$R" && zip -q "mv100-mdmo1g-stock-restore-$STAMP.zip" bootargs.bin README.txt )
mv "$R/mv100-mdmo1g-stock-restore-$STAMP.zip" "$DIST/"

ls -l "$DIST"/mv100-mdmo1g-probe-*.zip "$DIST"/mv100-mdmo1g-stock-restore-*.zip
