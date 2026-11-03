#!/usr/bin/env bash
# Assemble U-disk flash packages (two variants) from kernel + rootfs artifacts.
#   variant "stock": keeps the factory hiboot in p1 (safest)
#   variant "sdk":   also flashes the SDK-built hiboot into p1 (last)
set -eo pipefail

DIST=${DIST:-dist}
KERNEL_IMG=${KERNEL_IMG:-$DIST/hi_kernel.bin}
FASTBOOT=${FASTBOOT:-$DIST/fastboot-burn.bin}
MODULES_TAR=${MODULES_TAR:-$DIST/modules.tar.gz}
ROOTFS_TAR=${ROOTFS_TAR:-$DIST/debian-rootfs-armhf-bookworm.tar.gz}
IMG_SIZE_MB=${IMG_SIZE_MB:-2048}
IMG_LABEL=${IMG_LABEL:-debian-rootfs}
ROOT_PASSWD=${ROOT_PASSWD:-ec6108v9c}
STAMP=${STAMP:-$(date -u +%Y%m%dT%H%M%SZ)}

ROOT_DIR=$(cd "$(dirname "$0")/.." && pwd)
cd "$ROOT_DIR"

WORK=build/package
rm -rf "$WORK"
mkdir -p "$WORK/root" "$DIST"

echo "== unpack rootfs + modules =="
sudo tar -xzf "$ROOTFS_TAR" -C "$WORK/root" --numeric-owner
if [ -f "$MODULES_TAR" ]; then
  echo "== install kernel modules into image =="
  sudo tar -xzf "$MODULES_TAR" -C "$WORK/root"
fi

echo "== create ${IMG_SIZE_MB} MiB ext4 image =="
rm -f "$WORK/debian.ext4"
truncate -s "$((IMG_SIZE_MB * 1024 * 1024))" "$WORK/debian.ext4"
sudo mkfs.ext4 -q -F -L "$IMG_LABEL" -d "$WORK/root" "$WORK/debian.ext4"

echo "== convert to sparse =="
python3 scripts/img2simg.py "$WORK/debian.ext4" "$WORK/debian.sparse"

build_variant() {
  variant=$1
  with_hiboot=$2
  dir="$WORK/pkg-$variant"
  pkg="$dir/mv100"
  rm -rf "$dir"
  mkdir -p "$pkg"

  cp "$WORK/debian.sparse" "$pkg/debian.ext4"
  cp "$KERNEL_IMG" "$pkg/hi_kernel.bin"
  K_SIZE=$(stat -c%s "$pkg/hi_kernel.bin")
  K_SECTORS=$(( (K_SIZE + 511) / 512 ))
  truncate -s "$((K_SECTORS * 512))" "$pkg/hi_kernel.bin"
  K_HEX=$(printf '0x%x' $K_SECTORS)
  R_HEX=$(printf '0x%x' $((IMG_SIZE_MB * 2048)))

  python3 scripts/mkbootargs.py scripts/env/runtime.env "$pkg/bootargs.bin"

  {
    echo "baudrate=115200"
    echo "ethaddr=00:11:22:33:44:55"
    echo "ipaddr=192.168.1.10"
    echo "netmask=255.255.255.0"
    echo "gatewayip=192.168.1.1"
    echo "serverip=192.168.1.1"
    if [ "$with_hiboot" = "1" ]; then
      echo "bootcmd=run flashkernel; run flashrootfs; run flashbootargs; run flashhiboot; reset"
    else
      echo "bootcmd=run flashkernel; run flashrootfs; run flashbootargs; reset"
    fi
    echo "bootdelay=0"
    echo "stdin=serial"
    echo "stdout=serial"
    echo "stderr=serial"
    echo "loadfileb=getinfo ddrfree; mw.b 0x1000000 0xFF 0x10000; fatload usb 0 0x1000000 mv100/bootargs.bin; crc32 1000000 10000"
    echo "loadfilek=fatload usb 0 0x1000000 mv100/hi_kernel.bin"
    echo "loadfiler=fatload usb 0 0x1000000 mv100/debian.ext4"
    echo "flashpartitionb=mmc write 0 0x1000000 0x800 0x80"
    echo "flashpartitionk=mmc write 0 0x1000000 0x7000 $K_HEX"
    echo "flashpartitionr=mmc write.ext4sp 0 0x1000000 0x131000 $R_HEX"
    echo "flashbootargs=run loadfileb flashpartitionb"
    echo "flashkernel=run loadfilek flashpartitionk"
    echo "flashrootfs=run loadfiler flashpartitionr"
    if [ "$with_hiboot" = "1" ]; then
      cp "$FASTBOOT" "$pkg/fastboot-burn.bin"
      H_SIZE=$(stat -c%s "$pkg/fastboot-burn.bin")
      H_SECTORS=$(( (H_SIZE + 511) / 512 ))
      truncate -s "$((H_SECTORS * 512))" "$pkg/fastboot-burn.bin"
      H_HEX=$(printf '0x%x' $H_SECTORS)
      echo "loadfileh=fatload usb 0 0x1000000 mv100/fastboot-burn.bin"
      echo "flashpartitionh=mmc write 0 0x1000000 0x0 $H_HEX"
      echo "flashhiboot=run loadfileh flashpartitionh"
    fi
  } > "$dir/flash.env"
  python3 scripts/mkbootargs.py "$dir/flash.env" "$dir/bootargs.bin"

  if [ "$with_hiboot" = "1" ]; then
    HIBOOT_LINE="     mv100/fastboot-burn.bin (SDK hiboot -> p1, written last)"
    HIBOOT_NOTE="p1 is replaced by the SDK hiboot at the very end."
  else
    HIBOOT_LINE=""
    HIBOOT_NOTE="p1 (factory hiboot) is left untouched - recommended."
  fi

  cat > "$dir/README.txt" <<EOF
EC6108V9C (Hi3798MV100) Debian armhf U-disk flash package ($variant hiboot)
built (UTC): $STAMP

1) Format a USB stick as FAT32 (MBR, single partition) and copy everything
   from this zip to its root:
     bootargs.bin        (flash script run by hiboot)
     README.txt
     mv100/bootargs.bin  (runtime env -> p2, root=/dev/mmcblk0p9)
     mv100/hi_kernel.bin (mainline 6.x uImage -> p6)
     mv100/debian.ext4   (sparse Debian rootfs -> p9)
$HIBOOT_LINE

2) Power off, insert the stick, power on while holding the recovery key so
   the hiboot picks up bootargs.bin from the stick.

3) The script writes p6 (kernel), p9 (rootfs) and p2 (bootargs), then resets.
   $HIBOOT_NOTE
   p3/p4/p5/p7/p8 are also left untouched by this package.

4) After reboot the box runs Debian from p9:
     serial console ttyAMA0 115200, login root / $ROOT_PASSWD
     first boot grows the filesystem to the end of the partition.
EOF

  ( cd "$dir" && zip -q -r "mv100-mdmo1g-debian-usb-flash-$variant-hiboot-$STAMP.zip" bootargs.bin README.txt mv100 )
  mv "$dir/mv100-mdmo1g-debian-usb-flash-$variant-hiboot-$STAMP.zip" "$DIST/"
  ls -l "$DIST/mv100-mdmo1g-debian-usb-flash-$variant-hiboot-$STAMP.zip"
}

echo "== build stock-hiboot variant =="
build_variant stock 0

echo "== build sdk-hiboot variant =="
if [ -f "$FASTBOOT" ]; then
  build_variant sdk 1
else
  echo "fastboot-burn.bin missing, sdk variant skipped"
fi
