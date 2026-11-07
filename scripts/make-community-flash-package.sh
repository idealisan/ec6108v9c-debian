#!/usr/bin/env bash
# Build a U-disk flash package using the COMMUNITY (ECOO) boot/flash method,
# but with a self-built Debian rootfs instead of the community Ubuntu blob.
#
#   U-disk root:  bootargs.bin  (CRC32 env, hiboot executes bootcmd)
#                 mv100/
#                   hi_kernel.bin        -> p6  (uImage, LBA 0x7000)
#                   bootargs.bin         -> p2  (runtime env, LBA 0x800)
#                   debian-root.ext4     -> p8  (Android sparse, LBA 0x31000)
#                   logo.img             -> p5  (4-4 DONE picture)
#                   stage0..3.img        -> p5  (per-step progress pictures)
#                   README.txt
#                 README.txt / SHA256SUMS.txt
#
# p1 (hiboot) is NEVER written. The two-stage OpenWrt relay (p7/p8) is gone:
# the rootfs is written straight into the last partition (p8: the 512M
# backup partition is reclaimed) and p2 points at root=/dev/mmcblk0p8.
#
# bootcmd is a serial '&&' chain: each successful step rewrites p5 with its
# own stage picture, and '; reset' always runs. So the picture hiboot shows
# after the reboot is the last step that completed - a failed flash is now
# visible on the screen instead of being silently swallowed by ';'.
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
# Static, pre-generated LOGO_TABLE containers. hiboot draws p5 before the
# kernel starts, so these pictures are visible even when Linux never boots.
# "Debian Linux" is the 4-4 DONE marker; stage0..3 are written after each
# successful flash step. All are committed assets - CI never generates images.
# To change the text, regenerate with scripts/make-flash-logo.py (offline
# tool) and commit the new .img files.
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

# ---- A. distinct boot logo + per-stage progress pictures -------------------
# All static assets, generated offline and committed; CI never builds images.
# p5 is rewritten after every successful flash step, so the picture hiboot
# shows after the reset is always the LAST step that completed (flash.env).
[ -f "$BOOT_LOGO" ] || { echo "boot logo asset missing: $BOOT_LOGO" >&2; exit 1; }
cp "$BOOT_LOGO" "$WORK/pkg/mv100/logo.img"
for stage in 0 1 2 3; do
  stage_src="patches/kernel/boot-logo-stage$stage.img"
  [ -f "$stage_src" ] || { echo "stage logo missing: $stage_src" >&2; exit 1; }
  cp "$stage_src" "$WORK/pkg/mv100/stage$stage.img"
done
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
# Serial chain: hush '&&' stops at the FIRST failure, so the p5 picture left
# behind is always the last step that completed. '; reset' is unconditional,
# so hiboot re-reads p5 and shows that picture even when the chain shorted.
# With the old ';' chain a failed write was swallowed and the final logo still
# appeared, which made the picture useless as a success signal.
bootcmd=run mark0 && run flashkernel && run mark1 && run flashrootfs && run mark2 && run flashbootargs && run mark3 && run flashlogo; reset
bootdelay=0
stdin=serial
stdout=serial
stderr=serial
flash_stamp=$STAMP
# Each mark writes its own stage picture into p5 (LBA 0x5000, 0x80 sectors).
# 0-4 START / 1-4 KERNEL OK / 2-4 ROOTFS OK / 3-4 ENV OK, then "Debian Linux"
# for 4-4 DONE (written by flashlogo itself).
mark0=fatload usb 0 0x1000000 mv100/stage0.img && mmc write 0 0x1000000 0x5000 0x80
mark1=fatload usb 0 0x1000000 mv100/stage1.img && mmc write 0 0x1000000 0x5000 0x80
mark2=fatload usb 0 0x1000000 mv100/stage2.img && mmc write 0 0x1000000 0x5000 0x80
mark3=fatload usb 0 0x1000000 mv100/stage3.img && mmc write 0 0x1000000 0x5000 0x80
# Every write step is also gated internally: a failed fatload must NEVER be
# followed by an mmc write, otherwise stale DDR data would be flashed. The
# informational commands stay on ';' so hush returns the fatload result.
flashkernel=fatload usb 0 0x1000000 mv100/hi_kernel.bin && mmc write 0 0x1000000 0x7000 $K_HEX
flashrootfs=getinfo ddrfree; fatload usb 0 0x1000000 mv100/debian-root.ext4 && mmc write.ext4sp 0 0x1000000 0x31000 $R_HEX
flashbootargs=mw.b 0x1000000 0xFF 0x10000; fatload usb 0 0x1000000 mv100/bootargs.bin && mmc write 0 0x1000000 0x800 0x80
flashlogo=fatload usb 0 0x1000000 mv100/logo.img && mmc write 0 0x1000000 0x5000 0x80
ENV_EOF
python3 scripts/mkbootargs.py "$WORK/flash.env" "$WORK/pkg/bootargs.bin"

cat > "$WORK/pkg/mv100/README.txt" <<EOF
EC6108V9C Debian USB flash payload (community boot method)
built (UTC): $STAMP
flash stamp: $STAMP

p1 hiboot is NOT touched by this package. Partitions written:
  p2 bootargs  LBA 0x800    runtime env, root=mmcblk0p8, 8-partition cmdline
  p5 logo      LBA 0x5000   progress picture, rewritten after EACH step
  p6 kernel    LBA 0x7000   mainline uImage (zImage + DTB)
  p8 rootfs    LBA 0x31000  Debian armhf, Android sparse ($IMG_SIZE_MB MiB)

First boot grows p8 with resize2fs to the rest of the eMMC.

HOW TO TELL HOW FAR THE FLASH GOT
  The flash script is a serial '&&' chain: it STOPS at the first failure and
  always resets afterwards. hiboot then draws p5, which holds the progress
  picture written by the LAST step that completed. Read it after the reboot:

    0-4 START        script started (U disk + bootargs.bin read OK),
                     but writing the kernel into p6 FAILED
    1-4 KERNEL OK    p6 written, but writing the rootfs into p8 FAILED
    2-4 ROOTFS OK    p8 written, but writing the p2 environment FAILED
    3-4 ENV OK       p2 written, but writing the final logo FAILED
    Debian Linux     ALL FOUR steps completed (4-4 DONE)
    community advert nothing ran - U disk files missing or bootcmd rejected

  These pictures are drawn by hiboot BEFORE the kernel starts, so they are
  visible even if our kernel never boots. A green band on top of the screen
  is a separate marker: it means the Linux kernel DID boot and reached our
  HDMI driver (see docs/024 section 6).

  p1 (hiboot) is never written, so every one of these outcomes is recoverable
  by simply re-flashing with the same U-disk method.
EOF

cat > "$WORK/pkg/README.txt" <<EOF
EC6108V9C (Hi3798MV100) Debian USB flash package
built (UTC): $STAMP
flash stamp: $STAMP

Layout (same shape as the community mv100-mdmo1g-usb-flash.zip):
  bootargs.bin           hiboot U-disk flashing script (CRC32 header)
  mv100/hi_kernel.bin    kernel uImage                    -> p6
  mv100/bootargs.bin     runtime environment              -> p2
  mv100/debian-root.ext4 Debian rootfs, Android sparse   -> p8
  mv100/logo.img         "Debian Linux" = all 4 steps OK -> p5
  mv100/stage0.img       0-4 START      progress picture -> p5
  mv100/stage1.img       1-4 KERNEL OK  progress picture -> p5
  mv100/stage2.img       2-4 ROOTFS OK  progress picture -> p5
  mv100/stage3.img       3-4 ENV OK     progress picture -> p5
  mv100/README.txt

  All stage*.img / logo.img files are required. Do not delete them: the
  serial flash chain fatloads a fresh picture after each successful step.

HOW TO FLASH
  1. Format a USB stick as FAT32 / MBR (single primary partition).
  2. Copy EVERYTHING in this directory to the stick root, keeping mv100/ intact.
  3. Power off, insert the stick, power on with the recovery pads shorted
     (the same trigger the community package uses).
  4. hiboot reads bootargs.bin, runs a serial chain that writes p6/p8/p2/p5,
     then resets automatically. Expect a couple of minutes of black screen
     while the rootfs is written.
  5. Unplug the stick after the first reboot.

HOW TO TELL HOW FAR THE FLASH GOT
  The chain uses hush '&&', so it stops at the FIRST failure and always
  resets. hiboot then draws p5, which holds the picture from the LAST step
  that succeeded. Read the text on screen after the reboot (see
  mv100/README.txt for the full table):

    0-4 START      -> kernel write (p6) failed
    1-4 KERNEL OK  -> rootfs write (p8) failed
    2-4 ROOTFS OK  -> env write (p2) failed
    3-4 ENV OK     -> final logo write failed
    Debian Linux   -> ALL FOUR steps completed
    old advert     -> nothing ran (missing files or rejected bootcmd)

  These pictures come from hiboot, BEFORE the kernel, so they work even when
  Linux never boots. A green band across the top of the screen is a separate
  signal meaning the Linux kernel itself booted and reached our HDMI driver.

  If SSH works, "cat /proc/cmdline" contains the flash stamp; pstore/ramoops
  keeps the panic log if the kernel boots and dies.

LOGIN (change the password at first login)
  SSH     ssh root@<dhcp-ip>     password $ROOT_PASSWD
  telnet  telnet <dhcp-ip>       plaintext, LAN debug only
  serial  ttyAMA0 115200         root / $ROOT_PASSWD

SAFETY
  - p1 (hiboot) is never written; the U-disk recovery path stays available,
    so ANY outcome can be recovered by re-flashing with the same method.
  - Rootfs is written to 98..482 MiB, clear of the community p9 (610 MiB).
    If the chain stops at step 0, p6 is untouched and the community kernel
    can still boot; a later failure means p6 was already replaced.
  - 8-partition blkdevparts layout; p5 (several times), p6 and p2 are
    rewritten; p1/p3/p4/p7 are untouched.

If the box ever fails to boot, re-flash the community Ubuntu package with
the same short-pads method - that path is proven to work.
EOF

( cd "$WORK/pkg" && sha256sum bootargs.bin mv100/* > SHA256SUMS.txt )
( cd "$WORK/pkg" && zip -q -r "$ROOT_DIR/$OUT" . )
echo "== done"
ls -lh "$OUT"
unzip -l "$OUT" | tail -12
