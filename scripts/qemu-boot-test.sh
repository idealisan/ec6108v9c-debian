#!/usr/bin/env bash
# Boot the Debian armhf rootfs in QEMU (ARM virt board) and verify that it
# comes up with a working SSH login.
#
# This is the "does it boot at all" gate before touching the real box: it
# exercises the rootfs, systemd, openssh, DHCP and the basic userland on a
# real ARM machine. SoC specific drivers (display, tsensor, WiFi) obviously
# cannot be tested here - they need the actual Hi3798MV100.
#
# Usage:
#   KERNEL=vmlinuz INITRD=initrd ROOTFS=rootfs.ext4 scripts/qemu-boot-test.sh
set -eo pipefail

KERNEL=${KERNEL:-build/qemu/vmlinuz}
INITRD=${INITRD:-build/qemu/initrd}
ROOTFS=${ROOTFS:-build/qemu/rootfs.ext4}
SSH_PORT=${SSH_PORT:-2222}
PASSWD=${PASSWD:-ec6108v9c}
TIMEOUT=${TIMEOUT:-420}
MEM=${MEM:-1024}
CONSOLE_LOG=${CONSOLE_LOG:-build/qemu-console.log}

for f in "$KERNEL" "$INITRD" "$ROOTFS"; do
  [ -f "$f" ] || { echo "missing input: $f" >&2; exit 2; }
done
command -v qemu-system-arm >/dev/null || { echo "qemu-system-arm not installed" >&2; exit 2; }
command -v sshpass >/dev/null || { echo "sshpass not installed" >&2; exit 2; }

mkdir -p "$(dirname "$CONSOLE_LOG")"
echo "== booting: kernel=$KERNEL initrd=$INITRD rootfs=$ROOTFS (mem $MEM M, ssh port $SSH_PORT)"

qemu-system-arm \
  -M virt -cpu cortex-a15 -m "$MEM" -nographic -no-reboot \
  -kernel "$KERNEL" -initrd "$INITRD" \
  -append "root=/dev/vda rw console=ttyAMA0,115200" \
  -drive file="$ROOTFS",if=none,format=raw,id=hd0 \
  -device virtio-blk-device,drive=hd0 \
  -netdev "user,id=net0,hostfwd=tcp:127.0.0.1:$SSH_PORT-:22" \
  -device virtio-net-device,netdev=net0 \
  > "$CONSOLE_LOG" 2>&1 &
QPID=$!
# The CI runner waits for every child process, so the emulator has to die for
# sure - a plain SIGTERM can leave it alive and stall the whole step.
cleanup() {
  kill "$QPID" 2>/dev/null || true
  sleep 1
  kill -9 "$QPID" 2>/dev/null || true
  wait "$QPID" 2>/dev/null || true
}
trap cleanup EXIT

SSH_OPTS="-p $SSH_PORT -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=5 -o LogLevel=ERROR"

ready=no
i=0
while [ $i -lt "$TIMEOUT" ]; do
  i=$((i + 1))
  if ! kill -0 "$QPID" 2>/dev/null; then
    echo "!! qemu exited early, console log tail:"
    tail -40 "$CONSOLE_LOG" >&2
    exit 1
  fi
  if sshpass -p "$PASSWD" ssh $SSH_OPTS root@127.0.0.1 'echo SSH_READY' 2>/dev/null | grep -q SSH_READY; then
    ready=yes
    echo "== SSH reachable after ${i}s"
    break
  fi
  sleep 1
done

if [ "$ready" != yes ]; then
  echo "!! SSH did not come up within $TIMEOUT s; console log tail:" >&2
  tail -60 "$CONSOLE_LOG" >&2
  exit 1
fi

echo
echo "== guest checks =="
set +e
sshpass -p "$PASSWD" ssh $SSH_OPTS root@127.0.0.1 '
  echo "--- uname"; uname -a
  echo "--- os-release"; head -3 /etc/os-release
  echo "--- arch"; dpkg --print-architecture
  echo "--- uptime"; cat /proc/uptime
  echo "--- interfaces"; ip -brief addr
  echo "--- default route"; ip route | head -3
  echo "--- services"; systemctl is-active ssh; systemctl is-active networking || true
  echo "--- disk"; df -h / | tail -1
  echo "--- tools"; for t in ip ssh systemctl python3 fbset iw wpa_supplicant; do printf "%s=%s " "$t" "$(command -v $t || echo missing)"; done; echo
'
rc=$?
set -e
echo
echo "== qemu console (tail)"
tail -25 "$CONSOLE_LOG"
cleanup
exit $rc
