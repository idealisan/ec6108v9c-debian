#!/usr/bin/env bash
# Build a Debian armhf root filesystem for EC6108V9C.
# Runs on an x86_64 host with debootstrap + qemu-user-static installed.
set -eo pipefail

SUITE=${SUITE:-bookworm}
ARCH=armhf
MIRROR=${MIRROR:-http://deb.debian.org/debian}
ROOT=${ROOT:-build/rootfs}
DIST=${DIST:-dist}
TARGET_HOST=${TARGET_HOST:-ec6108v9c}
ROOT_PASSWD=${ROOT_PASSWD:-ec6108v9c}

ROOT_DIR=$(cd "$(dirname "$0")/.." && pwd)
cd "$ROOT_DIR"

sudo rm -rf "$ROOT"
mkdir -p "$ROOT" "$DIST"

echo "== debootstrap $SUITE/$ARCH (stage 1) =="
sudo debootstrap --arch="$ARCH" --variant=minbase --foreign \
  --include=ca-certificates,locales,sudo,openssh-server,systemd-sysv,ifupdown,iproute2,isc-dhcp-client,netbase,curl,wget,vim-tiny,parted,e2fsprogs,udev,htop,rsync,tzdata \
  "$SUITE" "$ROOT" "$MIRROR"

sudo cp /usr/bin/qemu-arm-static "$ROOT/usr/bin/"

cleanup() {
  for mnt in dev/pts dev proc sys; do
    sudo umount -l "$ROOT/$mnt" 2>/dev/null || true
  done
}
trap cleanup EXIT

sudo mount -t proc proc "$ROOT/proc"
sudo mount -t sysfs sysfs "$ROOT/sys"
sudo mount --bind /dev "$ROOT/dev"
sudo mount --bind /dev/pts "$ROOT/dev/pts"

echo "== debootstrap stage 2 =="
sudo chroot "$ROOT" /debootstrap/debootstrap --second-stage
sudo chroot "$ROOT" apt-get clean

echo "== configure system =="
echo "$TARGET_HOST" | sudo tee "$ROOT/etc/hostname" >/dev/null
sudo tee "$ROOT/etc/hosts" >/dev/null <<EOF
127.0.0.1 localhost
127.0.1.1 $TARGET_HOST
::1 localhost ip6-localhost ip6-loopback
EOF

# root is mounted by the kernel (root= on cmdline); keep fstab free of a
# hard-coded root device so the same image works on eMMC and on live-USB.
sudo tee "$ROOT/etc/fstab" >/dev/null <<EOF
proc /proc proc defaults 0 0
devpts /dev/pts devpts defaults 0 0
tmpfs /tmp tmpfs defaults 0 0
EOF

# serial console on ttyAMA0
sudo mkdir -p "$ROOT/etc/systemd/system/getty.target.wants"
sudo ln -sf /lib/systemd/system/serial-getty@.service \
    "$ROOT/etc/systemd/system/getty.target.wants/serial-getty@ttyAMA0.service"

# DHCP on the single hisi-femac port
sudo tee "$ROOT/etc/network/interfaces" >/dev/null <<EOF
auto lo
iface lo inet loopback

auto eth0
iface eth0 inet dhcp
EOF

# ssh / root password
sudo sed -i 's/^#*PermitRootLogin.*/PermitRootLogin yes/' "$ROOT/etc/ssh/sshd_config"
sudo sed -i 's/^#*PasswordAuthentication.*/PasswordAuthentication yes/' "$ROOT/etc/ssh/sshd_config"
echo "root:$ROOT_PASSWD" | sudo chroot "$ROOT" chpasswd

# grow the root filesystem once, on first boot
sudo tee "$ROOT/etc/systemd/system/resize-rootfs.service" >/dev/null <<EOF
[Unit]
Description=Grow the root filesystem to fill the ubuntu partition
After=local-fs.target

[Service]
Type=oneshot
ExecStart=/bin/sh -c 'dev=$$(findmnt -n -o SOURCE /); [ -n "$$dev" ] && /sbin/resize2fs "$$dev" || true'
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF
sudo ln -sf /etc/systemd/system/resize-rootfs.service \
    "$ROOT/etc/systemd/system/multi-user.target.wants/resize-rootfs.service"

sudo tee "$ROOT/etc/motd" >/dev/null <<EOF
EC6108V9C / Hi3798MV100 - Debian $SUITE armhf
serial console: ttyAMA0 115200, login root
EOF

echo "== shrink =="
sudo rm -rf "$ROOT/var/lib/apt/lists/"*
sudo rm -f "$ROOT/usr/bin/qemu-arm-static"

cleanup
trap - EXIT

sudo tar --numeric-owner -czf "$DIST/debian-rootfs-$ARCH-$SUITE.tar.gz" -C "$ROOT" .
ls -l "$DIST/debian-rootfs-$ARCH-$SUITE.tar.gz"
