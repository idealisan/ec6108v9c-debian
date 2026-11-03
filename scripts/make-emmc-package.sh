#!/usr/bin/env bash
# Build the eMMC install package that NEVER touches p1:
#   p11 <- Android boot.img wrapping our Linux kernel (stock hiboot boots it)
#   p16 <- Debian rootfs (userdata partition, 6 GB)
#   p2  <- bootargs with root=/dev/mmcblk0p16 (stock blkdevparts kept)
set -eo pipefail

DIST=${DIST:-dist}
STAMP=${STAMP:-$(date -u +%Y%m%dT%H%M%SZ)}
KERNEL=${KERNEL:-$DIST/zImage-dtb}
ROOTFS_TAR=${ROOTFS_TAR:-$DIST/debian-rootfs-armhf-bookworm.tar.gz}
MODULES_TAR=${MODULES_TAR:-$DIST/modules.tar.gz}
IMG_MB=${IMG_MB:-2048}
ROOT_PASSWD=${ROOT_PASSWD:-ec6108v9c}

ROOT_DIR=$(cd "$(dirname "$0")/.." && pwd)
cd "$ROOT_DIR"
WORK=build/emmc
PKG=$WORK/mv100
rm -rf "$WORK"; mkdir -p "$PKG" "$WORK/root" "$DIST"

BLKDEVPARTS="mmcblk0:1M(fastboot),4M(bootargs),16M(recovery),1M(deviceinfo),4M(baseparam),4M(pqparam),4M(logo),16M(fastplay),8M(misc),24M(factory),12M(kernel),8M(iptv_data),340M(backup),340M(cache),520M(system),-(userdata)"

echo "== rootfs image =="
sudo tar -xzf "$ROOTFS_TAR" -C "$WORK/root" --numeric-owner
[ -f "$MODULES_TAR" ] && sudo tar -xzf "$MODULES_TAR" -C "$WORK/root"
rm -f "$WORK/rootfs.img"
truncate -s "${IMG_MB}M" "$WORK/rootfs.img"
sudo mke2fs -q -F -t ext4 -L debian-root -d "$WORK/root" "$WORK/rootfs.img"
python3 scripts/img2simg.py "$WORK/rootfs.img" "$PKG/rootfs.ext4"

echo "== boot.img (Android format, wraps our kernel) =="
python3 scripts/mk-android-bootimg.py "$KERNEL" "$PKG/boot.img" \
    --cmdline "coherent_pool=2M console=ttyAMA0,115200 root=/dev/mmcblk0p16 rootfstype=ext4 rootwait rw blkdevparts=$BLKDEVPARTS"
B_SIZE=$(stat -c%s "$PKG/boot.img")
[ "$B_SIZE" -le $((12*1024*1024)) ] || { echo "boot.img exceeds the 12 MiB kernel partition" >&2; exit 1; }
B_SECTORS=$(( (B_SIZE + 511) / 512 ))
truncate -s "$((B_SECTORS * 512))" "$PKG/boot.img"
B_HEX=$(printf '0x%x' $B_SECTORS)
R_HEX=$(printf '0x%x' $((IMG_MB * 2048)))

echo "== runtime bootargs (p2) =="
cat > "$WORK/runtime.env" <<EOF
bootcmd=mmc read 0 0x1FFBFC0 0x29000 0x6000; bootm 0x1FFBFC0
bootargs=coherent_pool=2M console=ttyAMA0,115200 root=/dev/mmcblk0p16 rootfstype=ext4 rootwait rw mem=1G mmz=ddr,0,0,400M blkdevparts=$BLKDEVPARTS
bootdelay=0
baudrate=115200
stdin=serial
stdout=serial
stderr=serial
EOF
python3 scripts/mkbootargs.py "$WORK/runtime.env" "$PKG/bootargs.bin"

echo "== flash script =="
cat > "$WORK/flash.env" <<EOF
baudrate=115200
bootdelay=0
stdin=serial
stdout=serial
stderr=serial
load11=fatload usb 0 0x1000000 mv100/boot.img
load16=fatload usb 0 0x1000000 mv100/rootfs.ext4
load2=fatload usb 0 0x1000000 mv100/bootargs.bin
f11=mmc write 0 0x1000000 0x29000 $B_HEX
f16=mmc write.ext4sp 0 0x1000000 0x28B000 $R_HEX
f2=mmc write 0 0x1000000 0x800 0x80
r11=run load11 f11
r16=run load16 f16
r2=run load2 f2
bootcmd=run r11; run r16; run r2; reset
EOF
python3 scripts/mkbootargs.py "$WORK/flash.env" "$WORK/bootargs-flash.bin"

cat > "$WORK/README.txt" <<EOF
EC6108V9C Debian install package (p1 is NEVER touched)
built (UTC): $STAMP

Writes only:
  p11 kernel  <- mv100/boot.img     (Android boot.img wrapping the Linux kernel)
  p16 userdata<- mv100/rootfs.ext4  (Debian rootfs, IMG_MB_PLACEHOLDER MiB)
  p2  bootargs<- mv100/bootargs.bin (root=/dev/mmcblk0p16)

How to flash:
  1. FAT32 stick, copy bootargs.bin (this zip's root) + the mv100/ folder.
  2. Power off, insert stick, short the recovery pads, power on.
  3. It writes p11 -> p16 -> p2 and resets. p1 is untouched.
  4. Boots Debian on p16; serial ttyAMA0 115200, root / $ROOT_PASSWD

Rollback (same short-circuit + stick):
  use the stock-restore package to write p02/p11/p16 back from the backup.
EOF
sed -i "s/IMG_MB_PLACEHOLDER/${IMG_MB}/" "$WORK/README.txt"

echo "== zip =="
cp "$WORK/bootargs-flash.bin" "$WORK/bootargs.bin"
( cd "$WORK" && zip -q -r "mv100-mdmo1g-debian-emmc-$STAMP.zip" bootargs.bin README.txt mv100 )
mv "$WORK/mv100-mdmo1g-debian-emmc-$STAMP.zip" "$DIST/"
ls -lh "$DIST/mv100-mdmo1g-debian-emmc-$STAMP.zip"
