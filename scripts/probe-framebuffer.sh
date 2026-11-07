#!/usr/bin/env bash
# Measure the framebuffer that hiboot / the community VO driver configured.
#
# WHY: our 6.x kernel has no Hisilicon VO/HDMI driver. It can only take over
# the framebuffer left by hiboot via "simple-framebuffer", which needs the
# physical address written into the DTS. That address is allocated at runtime,
# so it must be read on a system that actually boots - the community Ubuntu,
# whose private hifb/VO/HDMI driver exposes it through /dev/fb0.
#
# Run FROM THE HOST (no need to copy this file onto the box):
#   ssh root@192.168.3.232 'bash -s' < scripts/probe-framebuffer.sh | tee TMP/fb-report.txt
#
# IMPORTANT: run it a SECOND time after a reboot and compare FB_BASE. If the
# address changes between boots, a static DTS address is not safe (see
# docs/020 for the fallback plan).
set -u

echo "================ 1. system ================"
date '+%Y-%m-%d %H:%M:%S %Z' 2>/dev/null
uname -a
cat /proc/cmdline 2>/dev/null

echo
echo "================ 2. framebuffer devices ================"
ls -l /dev/fb* 2>&1
cat /proc/fb 2>&1
ls /sys/class/graphics/ 2>&1

echo
echo "================ 3. ioctl on /dev/fb0 (THE PHYSICAL ADDRESS) ================"
if command -v python3 >/dev/null 2>&1; then
python3 - <<'PY'
import fcntl, struct, os, sys

FBIOGET_VSCREENINFO = 0x4600
FBIOGET_FSCREENINFO = 0x4602
FIX_LEN = 68          # struct fb_fix_screeninfo on 32-bit armhf
VAR_LEN = 160

BPP_FORMATS = {
    (32, 16, 8, 0, 8): ('a8r8g8b8', 'ARGB8888'),
    (32, 16, 8, 0, 0): ('x8r8g8b8', 'XRGB8888'),
    (32, 0, 8, 16, 8): ('a8b8g8r8', 'ABGR8888'),
    (32, 0, 8, 16, 0): ('x8b8g8r8', 'XBGR8888'),
    (24, 16, 8, 0, 0): ('r8g8b8', 'RGB888'),
    (16, 11, 5, 0, 0): ('r5g6b5', 'RGB565'),
}

def ioctl(fd, req, size):
    return fcntl.ioctl(fd, req, bytes(size))

path = '/dev/fb0'
if not os.path.exists(path):
    print('  /dev/fb0 not found - is the community display driver loaded?')
    sys.exit(0)
try:
    f = open(path, 'rb')
except OSError as e:
    print('  cannot open /dev/fb0:', e)
    sys.exit(0)

try:
    fix = ioctl(f.fileno(), FBIOGET_FSCREENINFO, FIX_LEN)
    smem_start = struct.unpack_from('<I', fix, 16)[0]
    smem_len   = struct.unpack_from('<I', fix, 20)[0]
    line_len   = struct.unpack_from('<I', fix, 44)[0]
    print('  smem_start  = 0x%08x  (%d MiB)' % (smem_start, smem_start // 1048576))
    print('  smem_len    = 0x%08x  (%d MiB)' % (smem_len, smem_len // 1048576))
    print('  line_length = %d bytes' % line_len)
except Exception as e:
    print('  FBIOGET_FSCREENINFO failed:', e)
    smem_start = smem_len = line_len = 0

try:
    var = ioctl(f.fileno(), FBIOGET_VSCREENINFO, VAR_LEN)
    xres = struct.unpack_from('<I', var, 0)[0]
    yres = struct.unpack_from('<I', var, 4)[0]
    bpp  = struct.unpack_from('<I', var, 24)[0]
    # fb_bitfield: offset(u32), length(u32), msb_right(u32) = 12 bytes each
    r_off, r_len = struct.unpack_from('<II', var, 32)
    g_off, g_len = struct.unpack_from('<II', var, 44)
    b_off, b_len = struct.unpack_from('<II', var, 56)
    t_off, t_len = struct.unpack_from('<II', var, 68)
    print('  xres/yres   = %d x %d' % (xres, yres))
    print('  bpp         = %d' % bpp)
    print('  red/green/blue/transp offsets = %d/%d/%d/%d (len %d/%d/%d/%d)' %
          (r_off, g_off, b_off, t_off, r_len, g_len, b_len, t_len))
    fmt = BPP_FORMATS.get((bpp, r_off, g_off, b_off, t_len))
    if fmt:
        print('  simplefb format = %s  (%s)' % fmt)
    else:
        print('  simplefb format = UNKNOWN - send these offsets back for mapping')
    stride = line_len or (xres * bpp // 8)
    print('')
    print('  -------- paste into workflow_dispatch --------')
    print('  fb_base   = 0x%08x' % smem_start)
    print('  fb_width  = %d' % xres)
    print('  fb_height = %d' % yres)
    print('  fb_stride = %d' % stride)
    print('  fb_format = %s' % (fmt[0] if fmt else 'a8r8g8b8'))
    print('  fb_size   = 0x%x' % (smem_len or (stride * yres)))
    print('  ----------------------------------------------')
except Exception as e:
    print('  FBIOGET_VSCREENINFO failed:', e)
PY
else
  echo "  python3 not available - falling back to fbset/dmesg below"
  command -v fbset >/dev/null 2>&1 && fbset -i 2>&1 || echo "  fbset not available either"
fi

echo
echo "================ 4. dmesg display lines ================"
dmesg 2>/dev/null | grep -iE "hifb|framebuffer|/dev/fb|fb[0-9]|vo |vdp|hdmi|logo|mmz|smem|phys addr|memory" | tail -60 || echo "  (dmesg restricted or empty)"

echo
echo "================ 5. /proc/iomem ================"
cat /proc/iomem 2>/dev/null | grep -iE "reserved|System RAM|display|fb|mmz|video" | head -30 || echo "  (unavailable)"

echo
echo "================ 6. sysfs fb0 attributes ================"
for f in /sys/class/graphics/fb0/*; do
  [ -f "$f" ] || continue
  v=$(cat "$f" 2>/dev/null | head -1)
  printf '  %-28s %s\n' "$(basename "$f")" "$v"
done

echo
echo "================ 7. VO register cross-check ==============="
echo "  DISABLED: reading VDP register pages via /dev/mem caused a kernel"
echo "  external abort and hung the HDMI kernel threads on the community 4.4"
echo "  kernel. ioctl on /dev/fb0 above is sufficient and side-effect free."
echo "  Use rootfs/usr/local/bin/ec6108-fbprobe only on the 6.x kernel."
echo
echo "================ 8. NEXT STEP ================"
echo "  Reboot the box and run this script AGAIN. Compare fb_base."
echo "  - same address  -> safe to write into the 6.x DTS (simplefb)"
echo "  - different     -> tell me; we need the dynamic-registration fallback"
echo "  Also send back sections 3/4/5/6 verbatim so the geometry can be verified."
