#!/usr/bin/env bash
# Assemble the U-disk flash package (mv100-mdmo1g layout) from the kernel and
# rootfs artifacts produced by build-kernel.sh / build-rootfs.sh.
set -eo pipefail

DIST=${DIST:-dist}
KERNEL_IMG=${KERNEL_IMG:-$DIST/hi_kernel.bin}
MODULES_TAR=${MODULES_TAR:-$DIST/modules.tar.gz}
ROOTFS_TAR=${ROOTFS_TAR:-$DIST/debian-rootfs-armhf-bookworm.tar.gz}
IMG_SIZE_MB=${IMG_SIZE_MB:-2048}
IMG_LABEL=${IMG_LABEL:-debian-rootfs}
ROOT_PASSWD=${ROOT_PASSWD:-ec6108v9c}
STAMP=${STAMP:-$(date -u +%Y%m%dT%H%M%SZ)}

ROOT_DIR=$(cd "$(dirname "$0")/.." && pwd)
cd "$ROOT_DIR"

WORK=build/package
PKG=$WORK/mv100
rm -rf "$WORK"
mkdir -p "$PKG" "$WORK/root"

echo "== unpack rootfs + modules =="
sudo tar -xzf "$ROOTFS_TAR" -C "$WORK/root" --numeric-owner
sudo tar -xzf "$MODULES_TAR" -C "$WORK/root"

echo "== create $IMG_SIZE_MB MiB ext4 image =="
rm -f "$WORK/debian.ext4"
truncate -s "$((IMG_SIZE_MB * 1024 * 1024))" "$WORK/debian.ext4"
sudo mkfs.ext4 -q -F -L "$IMG_LABEL" -d "$WORK/root" "$WORK/debian.ext4"

echo "== convert to sparse =="
python3 scripts/img2simg.py "$WORK/debian.ext4" "$PKG/debian.ext4"

echo "== kernel =="
cp "$KERNEL_IMG" "$PKG/hi_kernel.bin"
K_SIZE=$(stat -c%s "$PKG/hi_kernel.bin")
K_SECTORS=$(( (K_SIZE + 511) / 512 ))
truncate -s "$((K_SECTORS * 512))" "$PKG/hi_kernel.bin"
K_HEX=$(printf '0x%x' $K_SECTORS)
R_HEX=$(printf '0x%x' $((IMG_SIZE_MB * 2048)))

echo "== runtime bootargs (p2, root=/dev/mmcblk0p9) =="
python3 scripts/mkbootargs.py scripts/env/runtime.env "$PKG/bootargs.bin"

echo "== flash script bootargs (U-disk root) =="
cat > "$WORK/flash.env" <<EOF
baudrate=115200
ethaddr=00:11:22:33:44:55
ipaddr=192.168.1.10
netmask=255.255.255.0
gatewayip=192.168.1.1
serverip=192.168.1.1
bootcmd=run flashkernel; run flashrootfs; run flashbootargs; reset
bootdelay=0
stdin=serial
stdout=serial
stderr=serial
loadfileb=getinfo ddrfree; mw.b 0x1000000 0xFF 0x10000; fatload usb 0 0x1000000 mv100/bootargs.bin; crc32 1000000 10000
loadfilek=fatload usb 0 0x1000000 mv100/hi_kernel.bin
loadfiler=fatload usb 0 0x1000000 mv100/debian.ext4
flashpartitionb=mmc write 0 0x1000000 0x800 0x80
flashpartitionk=mmc write 0 0x1000000 0x7000 $K_HEX
flashpartitionr=mmc write.ext4sp 0 0x1000000 0x131000 $R_HEX
flashbootargs=run loadfileb flashpartitionb
flashkernel=run loadfilek flashpartitionk
flashrootfs=run loadfiler flashpartitionr
EOF
python3 scripts/mkbootargs.py "$WORK/flash.env" "$WORK/bootargs.bin"

echo "== package README =="
cat > "$WORK/README.txt" <<EOF
EC6108V9C (Hi3798MV100) Debian armhf U-disk flash package
built (UTC): $STAMP

1) Format a USB stick as FAT32 and copy everything from this zip to its root:
     bootargs.bin        (flash script run by hiboot)
     README.txt
     mv100/bootargs.bin  (runtime env -> p2, root=/dev/mmcblk0p9)
     mv100/hi_kernel.bin (linux uImage -> p6)
     mv100/debian.ext4   (sparse Debian rootfs -> p9)

2) Power off, insert the USB stick, power on while holding the recovery key
   so the hiboot picks up bootargs.bin from the stick (see docs/report.md).

3) The script writes p6 and p9 and then p2, and resets. p1/p3/p4/p5/p7/p8
   are left untouched.

4) After reboot the box runs Debian from p9:
     serial console ttyAMA0 115200, login root / $ROOT_PASSWD
     first boot grows the filesystem to the end of the partition.
EOF

echo "== zip =="
( cd "$WORK" && zip -q -r "mv100-mdmo1g-debian-usb-flash-$STAMP.zip" bootargs.bin README.txt mv100 )
mv "$WORK/mv100-mdmo1g-debian-usb-flash-$STAMP.zip" "$DIST/"
ls -l "$DIST/mv100-mdmo1g-debian-usb-flash-$STAMP.zip"
