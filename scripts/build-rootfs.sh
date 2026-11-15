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
  systemd-sysv systemd udev dbus kmod systemd-timesyncd fake-hwclock
  ifupdown iproute2 isc-dhcp-client netbase net-tools iputils-ping ethtool
  wpasupplicant wireless-tools wireless-regdb firmware-realtek
  iw rfkill dnsutils netcat-openbsd
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
# Keep the ifupdown file minimal: systemd-networkd owns every interface
# (10-eth0.network / 20-wlan.network). An "allow-hotplug wlan0" stanza here
# made udev fire ifup@wlan0.service, which failed (no wpa_supplicant.conf yet,
# and its if-pre-up.d hook cannot create /dev/stderr) and left systemd
# "degraded" on every boot. Connect WiFi with: ec6108-wifi '<SSID>' '<pass>'
sudo tee "$ROOT/etc/network/interfaces" >/dev/null <<'IF_EOF'
auto lo
iface lo inet loopback
IF_EOF

# ---- SSH ----
sudo sed -i "s/^#*PermitRootLogin.*/PermitRootLogin yes/" "$ROOT/etc/ssh/sshd_config"
sudo sed -i "s/^#*PasswordAuthentication.*/PasswordAuthentication yes/" "$ROOT/etc/ssh/sshd_config"
# Clients (e.g. terminal apps) send LANG=en_US.UTF-8 by default via
# AcceptEnv, but this image never runs locale-gen, so that locale does not
# exist -> "Cannot set LC_CTYPE to default locale" and programs fall back to
# C/ASCII behaviour (Chinese filenames quoted as \xxx, broken sorting, etc).
# C.UTF-8 is built into glibc >= 2.35 (bookworm has 2.36) and needs NO locale
# files, so it survives the shrink step below. Refuse the client's LANG and
# pin C.UTF-8 as the system default.
sudo sed -i "s/^AcceptEnv LANG LC_\*/#AcceptEnv LANG LC_*/" "$ROOT/etc/ssh/sshd_config"
sudo tee "$ROOT/etc/default/locale" >/dev/null <<'LOCALE_EOF'
LANG=C.UTF-8
LOCALE_EOF
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
# Match by name using a glob, and do not require a carrier before configuring:
# the internal FEPHY may not report link immediately (or at all if the generic
# PHY driver is used), and networkd would otherwise wait forever and never
# request a lease. The kernel cmdline carries net.ifnames=0, so the interface
# stays eth0 rather than being renamed by udev.
sudo tee "$ROOT/etc/systemd/network/10-eth0.network" >/dev/null <<'NET_EOF'
[Match]
Name=eth*

[Network]
DHCP=ipv4
IPv6AcceptRA=yes
ConfigureWithoutCarrier=yes

[DHCP]
RouteMetric=10
NET_EOF
sudo tee "$ROOT/etc/systemd/network/20-wlan.network" >/dev/null <<'NET_EOF'
[Match]
Name=wl*

[Network]
DHCP=ipv4
IPv6AcceptRA=yes
ConfigureWithoutCarrier=yes
NET_EOF
sudo ln -sf /lib/systemd/system/systemd-networkd.service "$ROOT/etc/systemd/system/multi-user.target.wants/systemd-networkd.service"
# NOTE: no sockets.target.wants/systemd-networkd.socket symlink here - that
# directory does not exist in a minimal debootstrap tree, and networkd is
# started directly by the service symlink above.
# ifupdown must stay out of the way now that networkd owns the interfaces
sudo ln -sf /dev/null "$ROOT/etc/systemd/system/multi-user.target.wants/networking.service"

# ---- DNS ---------------------------------------------------------------
# debootstrap leaves a copy of the BUILD HOST's stub-resolv.conf at
# /etc/resolv.conf ("nameserver 127.0.0.53" + a build-host search domain).
# This minimal tree has neither systemd-resolved nor resolvconf, so nobody
# listens on that stub and DNS is dead after every flash. Ship a static
# fallback and rebuild it at boot from the DNS networkd learned via DHCP.
sudo tee "$ROOT/etc/resolv.conf" >/dev/null <<'RESOLV_EOF'
# static fallback; rewritten at boot by ec6108-dns-init with DHCP DNS
nameserver 223.5.5.5
nameserver 119.29.29.29
nameserver 8.8.8.8
options timeout:2 attempts:2
RESOLV_EOF
sudo tee "$ROOT/etc/systemd/system/ec6108-dns-init.service" >/dev/null <<'UNIT_EOF'
[Unit]
Description=Rebuild /etc/resolv.conf from DHCP DNS at boot
After=systemd-networkd.service
Wants=systemd-networkd.service

[Service]
Type=oneshot
ExecStart=/usr/local/bin/ec6108-dns-init
TimeoutStartSec=25

[Install]
WantedBy=multi-user.target
UNIT_EOF
sudo ln -sf /etc/systemd/system/ec6108-dns-init.service \
    "$ROOT/etc/systemd/system/multi-user.target.wants/ec6108-dns-init.service"

# ---- time: no hardware RTC, so use Debian's file-backed software clock ----
# The mainline kernel has CONFIG_RTC_CLASS off and the DTB carries no rtc
# node: there is no /dev/rtc and no battery, so a cold boot would otherwise
# fall back to an old default date and apt rejects "not valid yet" Release
# files. Use the standard RTC-less stack (same as Raspberry Pi images):
#   * fake-hwclock - saves the clock to /etc/fake-hwclock.data on shutdown
#                    and restores it on boot (ExecStart=load / ExecStop=save).
#                    'load' refuses to move the clock backwards, so it never
#                    fights systemd-timesyncd's NTP-synced value.
#   * clock-epoch  - systemd >= 246 uses this file's mtime as a lower bound
#                    for the system clock at PID1 startup (first boot).
#   * timesyncd    - NTP discipline (UDP/123 verified reachable).
# Debian postinst already enables both services into sysinit.target.wants;
# the symlinks below are an explicit chroot fallback.
sudo mkdir -p "$ROOT/etc/systemd/system/sysinit.target.wants"
sudo ln -sf /lib/systemd/system/fake-hwclock.service \
    "$ROOT/etc/systemd/system/sysinit.target.wants/fake-hwclock.service"
sudo ln -sf /lib/systemd/system/systemd-timesyncd.service \
    "$ROOT/etc/systemd/system/sysinit.target.wants/systemd-timesyncd.service"
sudo mkdir -p "$ROOT/etc/systemd/timesyncd.conf.d"
sudo tee "$ROOT/etc/systemd/timesyncd.conf.d/10-ec6108.conf" >/dev/null <<'NTP_EOF'
[Time]
NTP=ntp.aliyun.com cn.pool.ntp.org time.windows.com pool.ntp.org
FallbackNTP=0.debian.pool.ntp.org 1.debian.pool.ntp.org 2.debian.pool.ntp.org
NTP_EOF
# Seed both file-backed clocks with the build time so the very first boot
# (before any NTP contact) is already a sane date and apt works offline.
date -u '+%Y-%m-%d %H:%M:%S' | sudo tee "$ROOT/etc/fake-hwclock.data" >/dev/null
sudo touch "$ROOT/usr/lib/clock-epoch"

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

# Login banner with LIVE addresses. agetty expands the \4 / \6 issue escapes
# into the box's IPv4 / IPv6 address each time a getty (re)starts, so the
# console always shows which IP to SSH to (no router lookup needed). A
# single-quoted heredoc keeps the backslashes intact; sed fills the two
# placeholders. The oneshot service below redraws the prompt after the DHCP
# lease arrives, since agetty may start before networkd gets an address.
sudo tee "$ROOT/etc/issue" >/dev/null <<'ISSUE_EOF'
EC6108V9C / Hi3798MV100 - Debian __SUITE__ armhf

  Network addresses:
    IPv4   \4
    IPv6   \6

SSH:    ssh root@\4        (password: __ROOT_PASSWD__)
Telnet: telnet \4          (plaintext, change the password first)
Serial: ttyAMA0 115200
WiFi:   ec6108-wifi '<SSID>' '<password>'   (then: iw dev wlan0 link)
ISSUE_EOF
sudo sed -i "s/__SUITE__/$SUITE/g; s/__ROOT_PASSWD__/$ROOT_PASSWD/g" "$ROOT/etc/issue"

# ---- login prompt address refresh ----
sudo tee "$ROOT/etc/systemd/system/ec6108-issue-refresh.service" >/dev/null <<'UNIT_EOF'
[Unit]
Description=Show current IP addresses on the console login prompt
After=systemd-networkd.service getty@tty1.service
Wants=systemd-networkd.service

[Service]
Type=oneshot
ExecStart=/usr/local/bin/ec6108-issue-refresh
TimeoutStartSec=15

[Install]
WantedBy=multi-user.target
UNIT_EOF
sudo ln -sf /etc/systemd/system/ec6108-issue-refresh.service \
    "$ROOT/etc/systemd/system/multi-user.target.wants/ec6108-issue-refresh.service"

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
sudo chmod 755 "$ROOT"/usr/local/bin/ec6108-*
echo "== shrink =="
# The image is written to the box by hiboot's "fatload", so every byte we
# drop here is a byte we do not have to push through the USB stick. The
# 1 GiB image with 327 MiB of payload stalled the flash script; keeping the
# payload lean is what makes the package flashable at all.
sudo rm -rf "$ROOT/var/lib/apt/lists/"*
sudo rm -f "$ROOT/usr/bin/qemu-arm-static"
sudo rm -rf "$ROOT/var/cache/"*
# docs, man pages and translations are ~84 MiB and useless on an appliance.
# C.UTF-8 is built into glibc and needs no locale files at all (see the
# /etc/default/locale setup above), so the whole locale directory can go
# (a debootstrap tree only ships gettext translations there).
sudo rm -rf "$ROOT/usr/share/doc" "$ROOT/usr/share/man" "$ROOT/usr/share/info"
sudo rm -rf "$ROOT/usr/share/locale"
# kernel modules are installed separately (modules.tar.gz)
sudo rm -rf "$ROOT/lib/modules/"*
echo "  payload now: $(du -sh "$ROOT" | cut -f1)"

cleanup
trap - EXIT

sudo tar --numeric-owner -czf "$DIST/debian-rootfs-$ARCH-$SUITE.tar.gz" -C "$ROOT" .
ls -l "$DIST/debian-rootfs-$ARCH-$SUITE.tar.gz"
