#!/usr/bin/env bash
# Build a dd-able live-USB image: MBR + FAT32 p1 (kernel + bootargs) + ext4 p2
# (Debian rootfs). Booting it requires the box's hiboot upgrade mode (short).
set -eo pipefail

DIST=${DIST:-dist}
STAMP=${STAMP:-$(date -u +%Y%m%dT%H%M%SZ)}
IMG_MB=${IMG_MB:-4096}          # whole-disk image size
BOOT_MB=${BOOT_MB:-512}         # FAT32 partition size
KERNEL=${KERNEL:-$DIST/zImage-dtb}
ROOTFS_TAR=${ROOTFS_TAR:-$DIST/debian-rootfs-armhf-bookworm.tar.gz}
MODULES_TAR=${MODULES_TAR:-$DIST/modules.tar.gz}
ROOT_PASSWD=${ROOT_PASSWD:-ec6108v9c}

ROOT_DIR=$(cd "$(dirname "$0")/.." && pwd)
cd "$ROOT_DIR"
WORK=build/liveusb
rm -rf "$WORK"; mkdir -p "$WORK/rootfs" "$DIST"

echo "== prepare rootfs tree =="
sudo tar -xzf "$ROOTFS_TAR" -C "$WORK/rootfs" --numeric-owner
[ -f "$MODULES_TAR" ] && sudo tar -xzf "$MODULES_TAR" -C "$WORK/rootfs"

echo "== build kernels =="
# uImage for the U-disk bootargs script
mkimage -A arm -O linux -T kernel -C none -a 0x08000000 -e 0x08000000 \
    -n "linux-hi3798mv100-usb" -d "$KERNEL" "$WORK/uImage"
# boot.img for the eMMC variant (kept here for reuse)
python3 scripts/mk-android-bootimg.py "$KERNEL" "$WORK/boot.img" \
    --cmdline "coherent_pool=2M console=ttyAMA0,115200 root=/dev/sda2 rootwait rw"

echo "== FAT32 partition =="
rm -f "$WORK/fat.img"
truncate -s "${BOOT_MB}M" "$WORK/fat.img"
mkfs.vfat -F 32 -n LIVE "$WORK/fat.img" >/dev/null
mmd -i "$WORK/fat.img" ::/live
mcopy -i "$WORK/fat.img" "$WORK/uImage" ::/live/uImage
mcopy -i "$WORK/fat.img" "$WORK/uImage" ::/live/uImage.bak
python3 scripts/mkbootargs.py <(printf 'baudrate=115200\nbootdelay=0\nstdin=serial\nstdout=serial\nstderr=serial\nbootcmd=fatload usb 0 0x08000000 live/uImage; bootm 0x08000000\n') "$WORK/bootargs.bin" >/dev/null
mcopy -i "$WORK/fat.img" "$WORK/bootargs.bin" ::/bootargs.bin

cat > "$WORK/README.txt" <<EOF
Live Linux USB for EC6108V9C (Hi3798MV100)
built (UTC): $STAMP

1. Write this image straight to a USB stick (destroys it):
     diskutil unmountDisk /dev/diskN
     sudo dd if=live-usb-hi3798mv100-$STAMP.img of=/dev/rdiskN bs=1m
2. Plug the stick into the box, short the recovery pads and power on
   (hiboot upgrade mode) - it loads the kernel from the stick and boots
   Debian with root on the stick's second partition.
3. Nothing is written to the box. Unplug and power-cycle to get Android back.

serial console: ttyAMA0 115200, login root / $ROOT_PASSWD
EOF
mcopy -i "$WORK/fat.img" "$WORK/README.txt" ::/README.txt

echo "== ext4 partition =="
EXT_MB=$((IMG_MB - BOOT_MB - 1))
rm -f "$WORK/root.img"
truncate -s "${EXT_MB}M" "$WORK/root.img"
sudo mke2fs -q -F -t ext4 -L live-root -d "$WORK/rootfs" "$WORK/root.img"

echo "== assemble disk image =="
rm -f "$WORK/hi3798mv100-live.img"
truncate -s "${IMG_MB}M" "$WORK/hi3798mv100-live.img"
parted -s "$WORK/hi3798mv100-live.img" mklabel msdos
parted -s "$WORK/hi3798mv100-live.img" mkpart primary fat32 1MiB $((1+BOOT_MB))MiB
parted -s "$WORK/hi3798mv100-live.img" mkpart primary ext4 $((1+BOOT_MB))MiB 100%
parted -s "$WORK/hi3798mv100-live.img" set 1 boot on
dd if="$WORK/fat.img"  of="$WORK/hi3798mv100-live.img" bs=1M seek=1 conv=notrunc status=none
dd if="$WORK/root.img" of="$WORK/hi3798mv100-live.img" bs=1M seek=$((1+BOOT_MB)) conv=notrunc status=none

echo "== compress =="
gzip -9 -c "$WORK/hi3798mv100-live.img" > "$DIST/hi3798mv100-live-usb-$STAMP.img.gz"
cp -f "$WORK/boot.img" "$DIST/boot.img"
ls -lh "$DIST/hi3798mv100-live-usb-$STAMP.img.gz" "$DIST/boot.img"
