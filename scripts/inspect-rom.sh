#!/usr/bin/env bash
# Inspect an Android box ROM package: report the real Android version, chip,
# HAL libraries and boot image details. Works on zip / folder inputs.
#
# usage: inspect-rom.sh <package.zip|dir> [workdir]
set -uo pipefail

SRC=${1:?usage: inspect-rom.sh <package.zip|dir>}
WORK=${2:-build/rom-inspect}
DEBUGFS=${DEBUGFS:-/opt/homebrew/opt/e2fsprogs/sbin/debugfs}
command -v "$DEBUGFS" >/dev/null 2>&1 || DEBUGFS=$(command -v debugfs || true)

ROOT_DIR=$(cd "$(dirname "$0")/.." && pwd)
PY_UNSPARSE="$ROOT_DIR/scripts/unsparse.py"

rm -rf "$WORK"; mkdir -p "$WORK/raw"

if [ -d "$SRC" ]; then
  cp -r "$SRC"/. "$WORK/raw/"
else
  unzip -q -o "$SRC" -d "$WORK/raw" || { echo "unzip failed"; exit 1; }
fi

echo "== files =="
find "$WORK/raw" -maxdepth 3 -type f \( -name '*.img' -o -name '*.bin' -o -name '*.zip' \) -exec ls -lh {} \; | awk '{print $5, $9}'

SPARSE_MAGIC="\x3a\xff\x26\xed"
report_build_prop() {
  img=$1
  [ -n "$DEBUGFS" ] || return 0
  for p in /system/build.prop /build.prop /system/etc/build.prop; do
    out=$("$DEBUGFS" -R "cat $p" "$img" 2>/dev/null | tr -d '\r')
    if [ -n "$out" ]; then
      echo "  --- $p ---"
      echo "$out" | grep -E 'ro\.build\.version\.(release|sdk)|ro\.product\.(model|device|name)|ro\.board\.platform|ro\.build\.description|ro\.build\.fingerprint|ro\.build\.date' | sed 's/^/    /'
      return 0
    fi
  done
}

report_boot_img() {
  python3 - "$1" <<'PY'
import struct, sys
p = sys.argv[1]
d = open(p,'rb').read()
if d[:8] != b'ANDROID!':
    sys.exit(0)
kaddr, ksize, raddr, rsize, saddr, ssize, tags, page = struct.unpack('<8I', d[8:40])
print('  boot.img: kernel=%d bytes page=%d' % (ksize, page))
k = d[page:page+ksize]
import re
m = re.search(rb'Linux version [0-9][^\x00\n]{0,120}', k)
if m:
    print('    kernel:', m.group().decode('latin1', 'ignore'))
name = d[page+ksize:page+ksize+rsize] if rsize else b''
if name and name[:2] == b'\x1f\x8b':
    print('    ramdisk: gzip')
PY
}

found=0
while IFS= read -r f; do
  magic=$(xxd -p -l 4 "$f" 2>/dev/null)
  if [ "$magic" = "3aff26ed" ]; then
    out="$f.raw"
    python3 "$PY_UNSPARSE" "$f" "$out" >/dev/null 2>&1 && f="$out"
  fi
  fs=$(xxd -s 1080 -l 2 -p "$f" 2>/dev/null)
  head=$(head -c 8 "$f" 2>/dev/null | tr -d '\0')
  if [ "$head" = "ANDROID!" ]; then
    echo "== $f (Android boot image) =="
    report_boot_img "$f"
    found=1
  elif [ "$fs" = "53ef" ]; then
    echo "== $f (ext4) =="
    if [ -n "$DEBUGFS" ]; then
      report_build_prop "$f"
      echo "    hw libs:"
      "$DEBUGFS" -R "ls /system/lib/hw" "$f" 2>/dev/null | tr -s ' ' '\n' | grep -E 'gralloc|hwcomposer|audio|lights|sensors|memtrack' | sed 's/^/      /' | head -12
    else
      echo "    debugfs not found, skipping"
    fi
    found=1
  fi
done < <(find "$WORK/raw" -type f -size +1M \( -name '*.img' -o -name '*.bin' \) | head -20)

[ "$found" = "1" ] || echo "no recognizable image found"
