#!/usr/bin/env bash
# Local QEMU boot test for the Debian armhf rootfs.
#
# Why this shape:
#   * The Debian *installer* netboot initrd boots the installer (it asks for a
#     language), so it can never bring up our rootfs.
#   * The Debian kernel package ships no initrd.img either.
#   => We boot the rootfs directly as an initramfs (cpio newc), which needs no
#      disk image (no mke2fs on macOS) and no pivot_root.
#     The virtio modules come from the same kernel package and are loaded by a
#     small systemd unit, because Debian builds virtio_net as a module.
#
# It answers the one question that matters before touching the real box:
# "does the rootfs come up and can we log in over SSH?"
#
# Usage:
#   ROOTFS_TAR=dist/debian-rootfs-armhf-bookworm.tar.gz scripts/qemu-local-test.sh
# On macOS also set CPIO=/opt/homebrew/opt/cpio/bin/cpio (GNU cpio is keg-only).
set -eo pipefail

ROOTFS_TAR=${ROOTFS_TAR:-build/qemu/rootfs.tar.gz}
WORK=${WORK:-build/qemu/local}
DEB_MIRROR=${DEB_MIRROR:-http://deb.debian.org/debian}
SSH_PORT=${SSH_PORT:-2222}
PASSWD=${PASSWD:-ec6108v9c}
TIMEOUT=${TIMEOUT:-420}
CONSOLE_LOG=${CONSOLE_LOG:-build/qemu/local-console.log}
CPIO=${CPIO:-cpio}

ROOT_DIR=$(cd "$(dirname "$0")/.." && pwd)
cd "$ROOT_DIR"

# The script chdirs into $WORK, so make every input/output path absolute up
# front - relative paths silently break once we change directory.
abs_path() {
  case "$1" in
    /*) printf '%s' "$1" ;;
    *)  printf '%s/%s' "$ROOT_DIR" "$1" ;;
  esac
}
ROOTFS_TAR=$(abs_path "$ROOTFS_TAR")
WORK=$(abs_path "$WORK")
CONSOLE_LOG=$(abs_path "$CONSOLE_LOG")

[ -f "$ROOTFS_TAR" ] || { echo "rootfs tarball not found: $ROOTFS_TAR" >&2; exit 2; }
command -v qemu-system-arm >/dev/null || { echo "qemu-system-arm missing" >&2; exit 2; }
command -v "$CPIO" >/dev/null || { echo "GNU cpio missing (brew install cpio)" >&2; exit 2; }
command -v python3 >/dev/null || { echo "python3 missing" >&2; exit 2; }

mkdir -p "$WORK"
cd "$WORK"

# ---------------------------------------------------------------- deb index
# Download the index to a file and parse it with python. A
# "curl | gunzip | awk ... exit" pipeline breaks the pipe when awk exits early,
# which makes curl fail with (23) under pipefail.
if [ ! -f Packages.gz ]; then
  echo "== fetching the armhf package index"
  curl -fsSL -o Packages.gz "$DEB_MIRROR/dists/bookworm/main/binary-armhf/Packages.gz"
fi

find_deb() {
  # $1: regexp matching the exact "Package:" value
  python3 - Packages.gz "$1" <<'PY'
import gzip, re, sys
pat = re.compile(rb'^Package: ' + sys.argv[2].encode() + rb'$')
found = False
for line in gzip.open(sys.argv[1], 'rb'):
    if line.startswith(b'Package: '):
        found = bool(pat.match(line.rstrip()))
    elif found and line.startswith(b'Filename: '):
        print(line.split(b': ', 1)[1].decode().strip())
        break
PY
}

# ---------------------------------------------------------------- kernel
if [ ! -f vmlinuz ]; then
  echo "== fetching the Debian armhf kernel package"
  URL=$(find_deb 'linux-image-6.1..*-armmp')
  [ -n "$URL" ] || { echo "kernel package not found in the index" >&2; exit 2; }
  curl -fsSL -o kernel.deb "$DEB_MIRROR/$URL"
  mkdir -p pkg
  (cd pkg && ar x ../kernel.deb && for f in data.tar.*; do tar xf "$f"; done)
  cp pkg/boot/vmlinuz-* vmlinuz
fi

# ---------------------------------------------------------------- rootfs tree
if [ ! -d tree/etc ]; then
  echo "== unpacking the rootfs"
  mkdir -p tree
  # /dev/* are device nodes; a non-root host (macOS) cannot mknod them, and
  # systemd mounts devtmpfs over /dev anyway, so skip them during extraction.
  tar -xzf "$ROOTFS_TAR" -C tree \
      --exclude='./dev/*' --exclude='dev/*'
fi

MODDIR=tree/lib/modules/virtio
mkdir -p "$MODDIR"
KVER=$(ls pkg/lib/modules 2>/dev/null | head -1)
if [ -n "$KVER" ]; then
  for m in drivers/virtio/virtio_mmio.ko net/core/failover.ko            drivers/net/net_failover.ko drivers/net/virtio_net.ko; do
    src="pkg/lib/modules/$KVER/kernel/$m"
    [ -f "$src" ] && cp "$src" "$MODDIR/"
  done
  # kmod provides insmod/modprobe (the rootfs does not ship it in base)
  if [ ! -e tree/usr/sbin/kmod ]; then
    KURL=$(find_deb 'kmod')
    [ -n "$KURL" ] || { echo "kmod package not found in the index" >&2; exit 2; }
    curl -fsSL -o kmod.deb "$DEB_MIRROR/$KURL"
    mkdir -p kmodpkg
    (cd kmodpkg && ar x ../kmod.deb && for f in data.tar.*; do tar xf "$f"; done)
    cp kmodpkg/bin/kmod tree/usr/sbin/kmod
    for t in modprobe insmod rmmod lsmod depmod; do
      ln -sf kmod "tree/usr/sbin/$t"
    done
  fi
fi

# The kernel only runs /init from an initramfs; without it, it insists on
# mounting root= as a block device and panics.
ln -sf sbin/init tree/init

mkdir -p tree/etc/systemd/system/multi-user.target.wants
cat > tree/etc/systemd/system/virtio-modules.service <<'UNIT_EOF'
[Unit]
Description=Load virtio modules (QEMU test)
Before=systemd-networkd.service
After=systemd-udev-settle.service
DefaultDependencies=no

[Service]
Type=oneshot
RemainAfterExit=yes
StandardOutput=journal+console
StandardError=journal+console
ExecStart=/bin/sh -c '/sbin/insmod /lib/modules/virtio/virtio_mmio.ko; /sbin/insmod /lib/modules/virtio/failover.ko; /sbin/insmod /lib/modules/virtio/net_failover.ko; /sbin/insmod /lib/modules/virtio/virtio_net.ko'

[Install]
WantedBy=multi-user.target
UNIT_EOF
ln -sf /etc/systemd/system/virtio-modules.service        tree/etc/systemd/system/multi-user.target.wants/virtio-modules.service

echo "== building the initramfs"
# "> rootfs.cpio" truncates the previous archive; "gzip -f" overwrites the .gz
(cd tree && find . -print0 | LC_ALL=C sort -z |     "$CPIO" --null -o -H newc --owner=0:0) > rootfs.cpio
gzip -1 -f rootfs.cpio

# ---------------------------------------------------------------- boot
echo "== booting"
qemu-system-arm   -M virt -cpu cortex-a15 -m 2048 -nographic -no-reboot   -kernel vmlinuz -initrd rootfs.cpio.gz   -append "root=/dev/ram0 rw console=ttyAMA0,115200"   -netdev "user,id=net0,hostfwd=tcp:127.0.0.1:$SSH_PORT-:22"   -device virtio-net-device,netdev=net0   </dev/null > "$CONSOLE_LOG" 2>&1 &
QPID=$!
cleanup() {
  kill "$QPID" 2>/dev/null || true
  sleep 1
  kill -9 "$QPID" 2>/dev/null || true
  wait "$QPID" 2>/dev/null || true
}
trap cleanup EXIT

SSH_OPTS="-p $SSH_PORT -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=8 -o ServerAliveInterval=5 -o ServerAliveCountMax=3 -o LogLevel=ERROR"
probe() {
  # Output goes to a file, not a pipe: timeout only kills sshpass, and a
  # surviving ssh child holding the pipe would block the shell forever.
  timeout -k 3 15 sshpass -p "$PASSWD" ssh $SSH_OPTS root@127.0.0.1 'echo SSH_READY'       > "$WORK/probe.out" 2>/dev/null
  grep -q SSH_READY "$WORK/probe.out"
}

ready=no
deadline=$((SECONDS + TIMEOUT))
while [ $SECONDS -lt $deadline ]; do
  if ! kill -0 "$QPID" 2>/dev/null; then
    echo "!! qemu exited early:" >&2
    tail -40 "$CONSOLE_LOG" >&2
    exit 1
  fi
  if probe; then
    ready=yes
    echo "== SSH reachable after $SECONDS s"
    break
  fi
  sleep 1
done

if [ "$ready" != yes ]; then
  echo "!! no SSH within $TIMEOUT s; console tail:" >&2
  tail -60 "$CONSOLE_LOG" >&2
  exit 1
fi

echo
echo "== guest checks =="
timeout -k 5 120 sshpass -p "$PASSWD" ssh $SSH_OPTS root@127.0.0.1 '
  echo "--- uname"; uname -a
  echo "--- os-release"; head -2 /etc/os-release
  echo "--- arch"; dpkg --print-architecture
  echo "--- interfaces"; ip -brief addr
  echo "--- services"; systemctl is-active ssh; systemctl is-active systemd-networkd || true
  echo "--- disk"; df -h / | tail -1
  echo "--- tools"; for t in ip ssh systemctl python3 fbset iw wpa_supplicant; do printf "%s=%s " "$t" "$(command -v $t || echo missing)"; done; echo
' > "$WORK/checks.out" 2>&1
cat "$WORK/checks.out"
echo
echo "== console tail"
tail -15 "$CONSOLE_LOG"
cleanup
exit 0
