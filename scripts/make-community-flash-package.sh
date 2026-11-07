#!/usr/bin/env bash
# Build a U-disk flash package using the COMMUNITY (ECOO) boot/flash method,
# but with a self-built Debian rootfs instead of the community Ubuntu blob.
#
#   U-disk root:  bootargs.bin  (CRC32 env, hiboot executes bootcmd)
#                 mv100/
#                   hi_kernel.bin        -> p6  (uImage, LBA 0x7000)
#                   bootargs.bin         -> p2  (runtime env, LBA 0x800)
#                   debian-root.ext4     -> p8  (Android sparse, LBA 0x31000)
#                   README.txt
#                 README.txt / SHA256SUMS.txt
#
# p1 (hiboot) is NEVER written. The two-stage OpenWrt relay (p7/p8) is gone:
# the rootfs is written straight into the last partition (p8: the 512M
# backup partition is reclaimed) and p2 points at root=/dev/mmcblk0p8.
set -eo pipefail

DIST=${DIST:-dist}
KERNEL_IMG=${KERNEL_IMG:-$DIST/hi_kernel.bin}
MODULES_TAR=${MODULES_TAR:-$DIST/modules.tar.gz}
ROOTFS_TAR=${ROOTFS_TAR:-$DIST/debian-rootfs-armhf-bookworm.tar.gz}
# 384 MiB image: the payload is ~240 MiB after the rootfs is trimmed, and
# 98 MiB + 384 MiB = 482 MiB stays clear of the community p9 (610 MiB),
# so a failed flash still leaves the community system bootable.
IMG_SIZE_MB=${IMG_SIZE_MB:-384}
ROOT_PASSWD=${ROOT_PASSWD:-ec6108v9c}
SUDO=${SUDO:-sudo}
MKFS=${MKFS:-mke2fs}
STAMP=${STAMP:-$(date -u +%Y%m%dT%H%M%SZ)}
OUT=${OUT:-$DIST/mv100-mdmo1g-debian-usb-flash-$STAMP.zip}
# Static, pre-generated "Debian Linux" boot logo (LOGO_TABLE container).
# hiboot draws p5 before the kernel starts, so a changed picture is visible
# even if the kernel never boots - the clearest "flash actually executed"
# signal. To change the text, regenerate with scripts/make-flash-logo.py
# (offline tool, never run in CI) and commit the new asset.
BOOT_LOGO=${BOOT_LOGO:-patches/kernel/boot-logo-debian.img}

ROOT_DIR=$(cd "$(dirname "$0")/.." && pwd)
cd "$ROOT_DIR"

# Shared partition / memory layout (single source of truth with the kernel
# DTS build).
if [ -f "$ROOT_DIR/configs/partition-layout.env" ]; then
  set -a
  . "$ROOT_DIR/configs/partition-layout.env"
  set +a
fi

WORK=build/community-package
rm -rf "$WORK"
mkdir -p "$WORK/root" "$WORK/pkg/mv100" "$DIST"

# ---- runtime env written into p2 ----
# Community 9-partition layout. root=p9 from the very first boot; no
# bootargs9-32.bin switch and no recoverybox relay.
cat > "$WORK/runtime.env" <<ENV_EOF
baudrate=115200
ethaddr=00:11:22:33:44:55
ipaddr=192.168.1.10
netmask=255.255.255.0
gatewayip=192.168.1.1
serverip=192.168.1.1
bootargs_512M=mem=512M
bootargs_768M=mem=768M
bootargs_1G=mem=1G
bootargs_2G=mem=2G
# NOTE: the kernel command line that actually matters is the one baked into
# the DTB (/chosen/bootargs, see configs/partition-layout.env). It overrides
# whatever the bootloader hands over, because the kernel is booted with
# CONFIG_ARM_APPENDED_DTB.
bootargs=${KERNEL_CMDLINE_NO_MEM}
flash_stamp=$STAMP
bootcmd=mmc read 0 0x1FFFFC0 0x7000 0xA000; bootm 0x1FFFFC0
bootdelay=0
stdin=serial
stdout=serial
stderr=serial
ENV_EOF
python3 scripts/mkbootargs.py "$WORK/runtime.env" "$WORK/pkg/mv100/bootargs.bin"

echo "== kernel =="
cp "$KERNEL_IMG" "$WORK/pkg/mv100/hi_kernel.bin"

# ---- A. distinct boot logo ------------------------------------------------
# Static asset, generated offline and committed. If the box still shows the
# community advert after flashing, p5 was never written (flash did not run).
[ -f "$BOOT_LOGO" ] || { echo "boot logo asset missing: $BOOT_LOGO" >&2; exit 1; }
cp "$BOOT_LOGO" "$WORK/pkg/mv100/logo.img"
K_SIZE=$(wc -c < "$WORK/pkg/mv100/hi_kernel.bin" | tr -d " ")
K_SECTORS=$(( (K_SIZE + 511) / 512 ))
truncate -s "$((K_SECTORS * 512))" "$WORK/pkg/mv100/hi_kernel.bin"
K_HEX=$(printf '0x%x' $K_SECTORS)
if [ $K_SECTORS -gt 40960 ]; then
  echo "kernel too large for p6 (20 MiB)" >&2; exit 1
fi

echo "== rootfs ext4 -> Android sparse =="
$SUDO tar -xzf "$ROOTFS_TAR" -C "$WORK/root" --numeric-owner
if [ -f "$MODULES_TAR" ]; then
  $SUDO tar -xzf "$MODULES_TAR" -C "$WORK/root"
fi
truncate -s "$((IMG_SIZE_MB * 1024 * 1024))" "$WORK/debian.ext4"
$SUDO $MKFS -q -F -t ext4 -L debian-root -d "$WORK/root" "$WORK/debian.ext4"
python3 scripts/img2simg.py "$WORK/debian.ext4" "$WORK/pkg/mv100/debian-root.ext4"
R_SECTORS=$(( IMG_SIZE_MB * 2048 ))
R_HEX=$(printf '0x%x' $R_SECTORS)

echo "== U-disk top-level bootargs.bin (flashing script) =="
cat > "$WORK/flash.env" <<ENV_EOF
baudrate=115200
ethaddr=00:11:22:33:44:55
ipaddr=192.168.1.10
netmask=255.255.255.0
gatewayip=192.168.1.1
serverip=192.168.1.1
bootargs_1G=mem=1G
bootcmd=run flashkernel; run flashrootfs; run flashbootargs; run flashlogo; reset
bootdelay=0
stdin=serial
stdout=serial
stderr=serial
flash_stamp=$STAMP
loadfilek=fatload usb 0 0x1000000 mv100/hi_kernel.bin
loadfiler=getinfo ddrfree; fatload usb 0 0x1000000 mv100/debian-root.ext4
loadfileb=getinfo ddrfree; mw.b 0x1000000 0xFF 0x10000; fatload usb 0 0x1000000 mv100/bootargs.bin; crc32 1000000 10000
loadfilel=fatload usb 0 0x1000000 mv100/logo.img
flashpartitionk=mmc write 0 0x1000000 0x7000 $K_HEX
flashpartitionr=mmc write.ext4sp 0 0x1000000 0x31000 $R_HEX
flashpartitionb=mmc write 0 0x1000000 0x800 0x80
flashpartitionl=mmc write 0 0x1000000 0x5000 0x80
flashkernel=run loadfilek flashpartitionk
flashrootfs=run loadfiler flashpartitionr
flashbootargs=run loadfileb flashpartitionb
flashlogo=run loadfilel flashpartitionl
ENV_EOF
python3 scripts/mkbootargs.py "$WORK/flash.env" "$WORK/pkg/bootargs.bin"

cat > "$WORK/pkg/mv100/README.txt" <<EOF
EC6108V9C Debian USB flash payload (community boot method)
built (UTC): $STAMP
flash stamp: $STAMP

p1 hiboot is NOT touched by this package. Partitions written:
  p2 bootargs  LBA 0x800    runtime env, root=mmcblk0p8, 8-partition cmdline
  p5 logo      LBA 0x5000   "Debian Linux" boot picture  <-- flash marker
  p6 kernel    LBA 0x7000   mainline uImage (zImage + DTB)
  p8 rootfs    LBA 0x31000  Debian armhf, Android sparse ($IMG_SIZE_MB MiB)

First boot grows p8 with resize2fs to the rest of the eMMC.

HOW TO TELL THE FLASH RAN
  After the flash, hiboot shows "Debian Linux" instead of the community
  advert. That picture comes from p5 and is drawn BEFORE the kernel starts,
  so it is visible even if our kernel fails to boot. If you still see the
  community advert, the flash script never reached the logo step.
EOF

cat > "$WORK/pkg/README.txt" <<EOF
EC6108V9C (Hi3798MV100) Debian USB flash package
built (UTC): $STAMP
flash stamp: $STAMP

Layout (same shape as the community mv100-mdmo1g-usb-flash.zip):
  bootargs.bin          hiboot U-disk flashing script (CRC32 header)
  mv100/hi_kernel.bin   kernel uImage                    -> p6
  mv100/bootargs.bin    runtime environment              -> p2
  mv100/logo.img        "Debian Linux" boot picture      -> p5  (flash marker)
  mv100/debian-root.ext4 Debian rootfs, Android sparse   -> p8
  mv100/README.txt

HOW TO FLASH
  1. Format a USB stick as FAT32 / MBR (single primary partition).
  2. Copy EVERYTHING in this directory to the stick root, keeping mv100/ intact.
  3. Power off, insert the stick, power on with the recovery pads shorted
     (the same trigger the community package uses).
  4. hiboot reads bootargs.bin, writes p6/p8/p2/p5, then resets automatically.
     Expect a couple of minutes of black screen while the rootfs is written.
  5. Unplug the stick after the first reboot.

HOW TO TELL THE FLASH RAN
  Boot shows "Debian Linux" instead of the community advert. The logo is
  drawn by hiboot before the kernel, so it proves the flash executed even if
  the kernel then fails. If SSH works, "cat /proc/cmdline" contains the
  flash stamp; pstore/ramoops keeps the panic log if it does not.

LOGIN (change the password at first login)
  SSH     ssh root@<dhcp-ip>     password $ROOT_PASSWD
  telnet  telnet <dhcp-ip>       plaintext, LAN debug only
  serial  ttyAMA0 115200         root / $ROOT_PASSWD

SAFETY
  - p1 (hiboot) is never written; the U-disk recovery path stays available.
  - Rootfs is written to 98..482 MiB, clear of the community p9 (610 MiB),
    so a failed flash still leaves the community system bootable.
  - 8-partition blkdevparts layout; p5/p6/p2 are rewritten, p1/p3/p4/p7
    untouched.

If the box ever fails to boot, re-flash the community Ubuntu package with
the same short-pads method - that path is proven to work.
EOF

( cd "$WORK/pkg" && sha256sum bootargs.bin mv100/* > SHA256SUMS.txt )
( cd "$WORK/pkg" && zip -q -r "$ROOT_DIR/$OUT" . )
echo "== done"
ls -lh "$OUT"
unzip -l "$OUT" | tail -12
