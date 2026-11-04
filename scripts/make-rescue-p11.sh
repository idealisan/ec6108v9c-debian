#!/usr/bin/env bash
# Build the "no-tweezers" rescue image: stock p11 kernel + busybox initramfs,
# wrapped in an Android boot.img that is dd'ed into p11 from a rooted Android.
#
#   KERNEL=p11_kernel.img BUSYBOX=/path/to/armhf/busybox \
#       bash scripts/make-rescue-p11.sh
#
# The initramfs brings up eth0 (192.168.3.240) and telnetd, paints the screen,
# and owns a 240 s watchdog that writes /data/stock_p11.img back to p11 and
# reboots when nobody commits, so a bad flash heals itself.
set -eo pipefail

KERNEL=${KERNEL:-}
BUSYBOX=${BUSYBOX:-}
DIST=${DIST:-dist}
OUT=${OUT:-$DIST/flash-p11}
IP=${IP:-192.168.3.240}
WATCHDOG=${WATCHDOG:-240}

ROOT_DIR=$(cd "$(dirname "$0")/.." && pwd)
cd "$ROOT_DIR"
[ -n "$KERNEL" ] || { echo "set KERNEL=<p11_kernel.img>" >&2; exit 1; }
[ -n "$BUSYBOX" ] || { echo "set BUSYBOX=<static armhf busybox>" >&2; exit 1; }

W=build/rescue
rm -rf "$W"; mkdir -p "$W/root/bin" "$W/root/dev" "$W/root/proc" "$W/root/sys" "$W/root/tmp" "$W/root/mnt/data" "$OUT"

if [ "$(head -c 8 "$KERNEL")" = "ANDROID!" ]; then
  python3 - "$KERNEL" "$W/zImage" <<'PY'
import struct, sys
d = open(sys.argv[1], 'rb').read()
ksize, kaddr, rsize, raddr, ssize, saddr, taddr, page = struct.unpack_from('<8I', d, 8)
open(sys.argv[2], 'wb').write(d[page:page + ksize])
PY
else
  cp -f "$KERNEL" "$W/zImage"
fi

CC=${CC:-"clang -target armv7a-linux-gnueabihf -march=armv7-a -mfloat-abi=soft -fuse-ld=lld"}
$CC -nostdlib -static -fno-builtin -O2 -Wl,-e,_start -o "$W/root/paint" probe/init.c

cp -f "$BUSYBOX" "$W/root/bin/busybox"
cp -f "$BUSYBOX" "$W/root/bin/sh"
chmod 755 "$W/root/bin/busybox" "$W/root/bin/sh" "$W/root/paint"

cat > "$W/root/init" <<INIT
#!/bin/sh
PATH=/bin
mount -t devtmpfs devtmpfs /dev 2>/dev/null
mkdir -p /dev/pts /proc /sys /tmp /mnt/data 2>/dev/null
mount -t devpts devpts /dev/pts 2>/dev/null
mount -t proc proc /proc 2>/dev/null
mount -t sysfs sysfs /sys 2>/dev/null
echo "== EC6108V9C rescue init =="
/paint &
sleep 1
if mount -t ext4 -o rw /dev/mmcblk0p16 /mnt/data 2>/dev/null; then
  echo "userdata mounted at /mnt/data"
else
  echo "WARN: cannot mount /dev/mmcblk0p16"
fi
if [ -f /mnt/data/stock_p11.img ]; then
  echo "rollback image present"
else
  echo "WARN: no /mnt/data/stock_p11.img - rollback disabled"
fi
for m in /mnt/data/modules/*.ko; do
  [ -f "$m" ] || continue
  case "$(basename $m)" in
    *eth*|*mac*|*net*|*phy*) insmod "$m" 2>/dev/null && echo "insmod $(basename $m)" ;;
  esac
done
i=0
while [ $i -lt 25 ]; do
  [ -d /sys/class/net/eth0 ] && break
  sleep 1; i=$((i+1))
done
ifconfig eth0 $IP netmask 255.255.255.0 up 2>/dev/null
echo "net: $(ifconfig eth0 2>/dev/null | tr '\\n' ' ')"
telnetd -l /bin/sh -p 23 2>/dev/null
echo "telnetd on $IP:23 - run 'touch /tmp/committed' within $WATCHDOG s"
(
  sleep $WATCHDOG
  if [ ! -e /tmp/committed ]; then
    if [ -f /mnt/data/stock_p11.img ]; then
      echo "watchdog: restoring stock p11"
      dd if=/mnt/data/stock_p11.img of=/dev/mmcblk0p11 bs=65536 2>/dev/null
      sync
      sleep 1
      reboot -f
    else
      echo "watchdog: no rollback image - staying up for telnet"
    fi
  fi
) &
while true; do sleep 3600; done
INIT
chmod 755 "$W/root/init"

python3 probe/mkcpio_dir.py "$W/root" "$W/ramdisk.gz"
python3 scripts/mk-android-bootimg.py "$W/zImage" "$OUT/rescue-boot.img" \
  --ramdisk "$W/ramdisk.gz" \
  --cmdline 'mem=1G mmz=ddr,0,0,400M coherent_pool=2M console=ttyAMA0,115200 blkdevparts=mmcblk0:1M(fastboot),4M(bootargs),16M(recovery),1M(deviceinfo),4M(baseparam),4M(pqparam),4M(logo),16M(fastplay),8M(misc),24M(factory),12M(kernel),8M(iptv_data),340M(backup),340M(cache),520M(system),-(userdata)' \
  --name "linux-rescue"
cp -f /dev/null /dev/null 2>/dev/null || true
ls -l "$OUT/rescue-boot.img"
