#!/usr/bin/env bash
# Build a Debian armhf root filesystem for EC6108V9C.
# Boots from the community 9-partition layout (root=/dev/mmcblk0p9).
# Provides SSH (openssh-server) and telnet (busybox telnetd) out of the box.
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

# Everything is a real Debian package, unlike the community image which
# ships an opaque encrypted blob as its root filesystem.
PACKAGES=(
  ca-certificates locales sudo login passwd
  openssh-server openssh-client
  busybox
  systemd-sysv systemd udev dbus kmod
  ifupdown iproute2 isc-dhcp-client netbase net-tools iputils-ping ethtool
  wpasupplicant wireless-tools wireless-regdb firmware-realtek
  curl wget rsync vim-tiny nano less htop procps psmisc
  e2fsprogs parted dosfstools util-linux mount findutils coreutils
  usbutils pciutils i2c-tools lsof strace tcpdump
  lm-sensors fbset kbd console-setup
  python3-minimal python3
  tzdata bash-completion tmux minicom
)
# firmware-realtek lives in non-free-firmware in bookworm.
COMPONENTS=${COMPONENTS:-main,contrib,non-free,non-free-firmware}

sudo rm -rf "$ROOT"
mkdir -p "$ROOT" "$DIST"

echo "== debootstrap $SUITE/$ARCH (stage 1) =="
sudo debootstrap --arch="$ARCH" --variant=minbase --foreign --components="$COMPONENTS" --include="$(IFS=,; echo "${PACKAGES[*]}")" "$SUITE" "$ROOT" "$MIRROR"

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

# root comes from the kernel cmdline (root=); fstab has no hard-coded device
sudo tee "$ROOT/etc/fstab" >/dev/null <<EOF
proc /proc proc defaults 0 0
devpts /dev/pts devpts defaults 0 0
tmpfs /tmp tmpfs defaults 0 0
EOF

# serial console on ttyAMA0 (115200, the box UART)
sudo mkdir -p "$ROOT/etc/systemd/system/getty.target.wants"
sudo ln -sf /lib/systemd/system/serial-getty@.service "$ROOT/etc/systemd/system/getty.target.wants/serial-getty@ttyAMA0.service"

# DHCP on the single hisi-femac port
sudo tee "$ROOT/etc/network/interfaces" >/dev/null <<EOF
auto lo
iface lo inet loopback
auto eth0
iface eth0 inet dhcp

# WiFi (RTL8188FU, mainline rtl8xxxu). Fill wpa_supplicant.conf with
# /usr/local/bin/ec6108-wifi <SSID> <password>, then ifup the interface.
allow-hotplug wlx8421f1edf583
iface wlx8421f1edf583 inet dhcp
    wpa-conf /etc/wpa_supplicant/wpa_supplicant.conf
EOF

# ---- SSH ----
sudo sed -i "s/^#*PermitRootLogin.*/PermitRootLogin yes/" "$ROOT/etc/ssh/sshd_config"
sudo sed -i "s/^#*PasswordAuthentication.*/PasswordAuthentication yes/" "$ROOT/etc/ssh/sshd_config"
# postinst normally creates host keys; regenerate defensively for first boot
sudo chroot "$ROOT" /usr/bin/ssh-keygen -A || true
sudo mkdir -p "$ROOT/etc/systemd/system/multi-user.target.wants"
sudo ln -sf /lib/systemd/system/ssh.service "$ROOT/etc/systemd/system/multi-user.target.wants/ssh.service"

# ---- networking ----
# ifupdown alone is fragile here: at boot the PHY link may not be up yet, so
# "dhclient" fails once and never retries - the box then boots without an
# IPv4 address and SSH is unreachable even though sshd is running.
# systemd-networkd waits for the carrier and keeps retrying the DHCP lease,
# so use it for the wired and the wireless interface.
sudo mkdir -p "$ROOT/etc/systemd/network"
sudo tee "$ROOT/etc/systemd/network/10-eth0.network" >/dev/null <<'NET_EOF'
[Match]
Name=eth0

[Network]
DHCP=yes
IPv6AcceptRA=yes

[DHCP]
RouteMetric=10
NET_EOF
sudo tee "$ROOT/etc/systemd/network/20-wlan.network" >/dev/null <<'NET_EOF'
[Match]
Name=wlx*

[Network]
DHCP=yes
IPv6AcceptRA=yes
NET_EOF
sudo ln -sf /lib/systemd/system/systemd-networkd.service "$ROOT/etc/systemd/system/multi-user.target.wants/systemd-networkd.service"
# NOTE: no sockets.target.wants/systemd-networkd.socket symlink here - that
# directory does not exist in a minimal debootstrap tree, and networkd is
# started directly by the service symlink above.
# ifupdown must stay out of the way now that networkd owns the interfaces
sudo ln -sf /dev/null "$ROOT/etc/systemd/system/multi-user.target.wants/networking.service"
# ... but keep the file for manual "ifup eth0" usage
sudo sed -i "s/^auto eth0/#auto eth0/; s/^iface eth0 inet dhcp/#iface eth0 inet dhcp/" "$ROOT/etc/network/interfaces"

# ---- telnet (busybox telnetd, standalone, no inetd needed) ----
sudo tee "$ROOT/etc/systemd/system/telnetd.service" >/dev/null <<'UNIT_EOF'
[Unit]
Description=Busybox telnet server (plaintext, LAN debug only)
After=network.target

[Service]
Type=simple
ExecStart=/bin/busybox telnetd -F -l /bin/login -p 23
Restart=always
RestartSec=2

[Install]
WantedBy=multi-user.target
UNIT_EOF
sudo ln -sf /etc/systemd/system/telnetd.service "$ROOT/etc/systemd/system/multi-user.target.wants/telnetd.service"

# login banner / credential hint
sudo tee "$ROOT/etc/issue" >/dev/null <<EOF
EC6108V9C / Hi3798MV100 - Debian $SUITE armhf
SSH:    ssh root@<dhcp-ip>    (password: $ROOT_PASSWD)
Telnet: telnet <dhcp-ip>     (plaintext, change the password first)
Serial: ttyAMA0 115200
EOF

# ---- root password ----
echo "root:$ROOT_PASSWD" | sudo chroot "$ROOT" chpasswd

# ---- grow root filesystem once, on first boot ----
# p9 is "-(ubuntu)", the whole remainder of the eMMC; the sparse image
# only carries a 1 GiB filesystem, so resize2fs stretches it to fit.
sudo tee "$ROOT/etc/systemd/system/resize-rootfs.service" >/dev/null <<'UNIT_EOF'
[Unit]
Description=Grow the root filesystem to fill p9
After=local-fs.target

[Service]
Type=oneshot
ExecStart=/bin/sh -c 'dev=$$(findmnt -n -o SOURCE /); [ -n "$$dev" ] && /sbin/resize2fs "$$dev" || true'
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
UNIT_EOF
sudo ln -sf /etc/systemd/system/resize-rootfs.service "$ROOT/etc/systemd/system/multi-user.target.wants/resize-rootfs.service"

sudo tee "$ROOT/etc/motd" >/dev/null <<EOF
EC6108V9C / Hi3798MV100 - Debian $SUITE armhf
serial console: ttyAMA0 115200, login root
EOF

echo "== device helper scripts =="
sudo cp -a "$ROOT_DIR/rootfs/usr/local/bin/." "$ROOT/usr/local/bin/"
sudo chown root:root "$ROOT"/usr/local/bin/ec6108-*
echo "== shrink =="
sudo rm -rf "$ROOT/var/lib/apt/lists/"*
sudo rm -f "$ROOT/usr/bin/qemu-arm-static"

cleanup
trap - EXIT

sudo tar --numeric-owner -czf "$DIST/debian-rootfs-$ARCH-$SUITE.tar.gz" -C "$ROOT" .
ls -l "$DIST/debian-rootfs-$ARCH-$SUITE.tar.gz"
