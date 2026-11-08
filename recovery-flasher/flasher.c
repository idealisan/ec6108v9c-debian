/* =============================================================================
 * recovery-flasher/flasher.c
 * EC6108V9C / Hi3798MV100 -- stock-recovery-kernel based AUTO FLASHER
 * =============================================================================
 * WHAT THIS IS
 *   A freestanding ARM-EABI Linux userspace program that REPLACES
 *   /sbin/recovery inside the STOCK Android recovery ramdisk. We keep the
 *   stock 3.10 kernel (it already has the hifb/VO/HDMI drivers that light the
 *   panel and register /dev/graphics/fb0) and replace only the userland.
 *
 *   The stock init.rc has `service recovery /sbin/recovery` and
 *   `class_start default` on boot, so Android init execs this program
 *   automatically -- NO menu, NO key, NO interaction (the box has none).
 *
 * FULLY AUTOMATIC BEHAVIOUR
 *   1. open /dev/graphics/fb0, FBIOGET_*SCREENINFO, mmap (fallback: write()).
 *   2. mkdir /usb; mount U-disk (/dev/block/sda1, vfat) -- recovery.fstab
 *      documents that U-disk path; our own mount means no dependence on
 *      /sbin/recovery's mount logic (which we are replacing).
 *   3. If /usb/flash.manifest exists, flash it: each line
 *          <src-full-path> <dest-lba-hex> <byte-count-hex>
 *      writes <src> into /dev/block/mmcblk0 at LBA <dest>, by raw 512-byte
 *      sectors. The progress bar advances after each item. NO manifest =>
 *      NO writes (pure display demo) -- so writing is gated by U-disk content,
 *      never by a menu.
 *   4. Never exit (keep fb0 fd open): hifb clears the framebuffer on close
 *      (docs/040). Endless animation also proves the program is alive.
 *
 * SAFETY
 *   - eMMC writes happen ONLY when a flash.manifest is present on the U-disk.
 *     Without it this is a pure display probe, harmless and always re-flashable.
 *   - Writes go to raw /dev/block/mmcblk0 by explicit LBA, so the Android
 *     16-partition blkdevparts in the kernel cmdline is irrelevant.
 *
 * BUILD (host clang, no cross-gcc, no libc, no sysroot):
 *   clang --target=armv7-unknown-linux-gnueabihf -fuse-ld=lld -static -nostdlib \
 *     -ffreestanding -fno-builtin -fno-stack-protector -O2 -o flasher flasher.c
 * ============================================================================= */

typedef unsigned int  u32;
typedef unsigned long ulong;
#define NULL ((void *)0)

/* ---- ARM EABI syscalls, r7 = number, r0..r5 = args, svc #0 ---- */
static inline long sc6(long n, long a, long b, long c, long d, long e, long f) {
    register long r7 __asm__("r7") = n;
    register long r0 __asm__("r0") = a;
    register long r1 __asm__("r1") = b;
    register long r2 __asm__("r2") = c;
    register long r3 __asm__("r3") = d;
    register long r4 __asm__("r4") = e;
    register long r5 __asm__("r5") = f;
    __asm__ volatile("svc #0" : "+r"(r0)
                     : "r"(r7), "r"(r1), "r"(r2), "r"(r3), "r"(r4), "r"(r5)
                     : "memory", "cc");
    return r0;
}
#define SC1(n,a)        sc6((n),(long)(a),0,0,0,0,0)
#define SC2(n,a,b)      sc6((n),(long)(a),(long)(b),0,0,0,0)
#define SC3(n,a,b,c)    sc6((n),(long)(a),(long)(b),(long)(c),0,0,0)
#define SC5(n,a,b,c,d,e) sc6((n),(long)(a),(long)(b),(long)(c),(long)(d),(long)(e),0)

#define NR_exit      1
#define NR_read      3
#define NR_write     4
#define NR_open      5
#define NR_close     6
#define NR_lseek     19
#define NR_mkdir     39
#define NR_mount     40
#define NR_ioctl     54
#define NR_fsync     118
#define NR_mmap2     192

#define O_RDONLY     0
#define O_RDWR       2
#define PROT_RW      3
#define MAP_SHARED   1
#define FBIOGET_VSCREENINFO 0x4600
#define FBIOGET_FSCREENINFO 0x4602
#define CHUNK        (64 * 1024)

/* ---- software unsigned divide (freestanding: no libgcc/__aeabi_uidiv) ---- */
u32 __aeabi_uidiv(u32 n, u32 d) {
    if (d == 0) return 0xffffffffu;
    u32 q = 0, r = 0;
    for (int i = 31; i >= 0; i--) {
        r = (r << 1) | ((n >> i) & 1u);
        if (r >= d) { r -= d; q |= (1u << i); }
    }
    return q;
}
typedef struct { u32 q, r; } uidivmod_t;
uidivmod_t __aeabi_uidivmod(u32 n, u32 d) {
    uidivmod_t v;
    v.q = __aeabi_uidiv(n, d);
    v.r = n - v.q * d;
    return v;                 /* AAPCS: 8-byte struct returns in r0,r1 */
}

/* ---- tiny local helpers (no libc) ---- */
static int slen(const char *s) { int n = 0; while (s[n]) n++; return n; }
static u32 rd32(const unsigned char *p, int o) {
    return (u32)p[o] | ((u32)p[o+1] << 8) | ((u32)p[o+2] << 16) | ((u32)p[o+3] << 24);
}
static u32 hexval(const char *s, int n) {
    u32 v = 0;
    for (int i = 0; i < n; i++) {
        char c = s[i]; u32 d;
        if (c >= '0' && c <= '9') d = (u32)(c - '0');
        else if (c >= 'a' && c <= 'f') d = (u32)(c - 'a' + 10);
        else if (c >= 'A' && c <= 'F') d = (u32)(c - 'A' + 10);
        else break;
        v = (v << 4) | d;
    }
    return v;
}
static void delay(void) { volatile unsigned long i; for (i = 0; i < 0x400000UL; i++) ; }

/* ---- framebuffer state ---- */
static volatile u32 *g_fb;          /* mmap base, or NULL for write() fallback */
static u32 g_len, g_stride, g_rows, g_cols, g_frame_words;
static int g_fbfd = -1;
static unsigned char g_chunk[CHUNK];          /* .bss: zero-filled by ELF loader */
static unsigned char g_man[8192];             /* manifest buffer */

/* stage colours (ARGB8888-ish; any non-zero value is visible) */
static const u32 COL_DONE[6] = {
    0xFF00FF00, 0xFF00FFC0, 0xFF40FF40, 0xFF80FF00, 0xFFC0FF00, 0xFFFFFF00
};
static const u32 COL_HDR[6] = {
    0xFFFF0000, 0xFFFF8000, 0xFFFFFF00, 0xFF00FFFF, 0xFF0080FF, 0xFFFF00FF
};
#define COL_TODO 0xFF102040

static int fb_init(void) {
    long fd = SC3(NR_open, "/dev/graphics/fb0", O_RDWR, 0);
    if (fd < 0) fd = SC3(NR_open, "/dev/fb0", O_RDWR, 0);
    if (fd < 0) return -1;
    g_fbfd = (int)fd;

    unsigned char var[256]; unsigned char fix[256];
    for (int i = 0; i < 256; i++) { var[i] = 0; fix[i] = 0; }
    SC3(NR_ioctl, g_fbfd, FBIOGET_VSCREENINFO, var);
    SC3(NR_ioctl, g_fbfd, FBIOGET_FSCREENINFO, fix);

    u32 xres = rd32(var, 0), yres = rd32(var, 4);
    u32 bpp  = rd32(var, 24);
    if (!bpp || bpp > 32) bpp = 32;
    if (!xres) xres = 1920;
    if (!yres) yres = 1080;

    g_len = rd32(fix, 20);                 /* smem_len */
    if (!g_len) g_len = xres * yres * (bpp / 8) * 2;
    g_stride = rd32(fix, 44);              /* line_length */
    if (g_stride < 64 || g_stride > 32768) g_stride = xres * (bpp / 8);

    g_frame_words = (g_len / 2) / 4;
    g_cols = g_stride / 4;
    g_rows = (g_len / 2) / (g_stride ? g_stride : 7680);
    if (!g_cols) g_cols = 1920;
    if (!g_rows) g_rows = 1080;

    long m = sc6(NR_mmap2, 0, (long)g_len, PROT_RW, MAP_SHARED, (long)g_fbfd, 0);
    /* Linux returns -errno as (unsigned)0xfffff001..0xffffffff on failure */
    if ((u32)m >= 0xfffff001u) g_fb = NULL;                      /* write() fallback */
    else g_fb = (volatile u32 *)m;
    return 0;
}

/* Draw a bar at pct (0..100) with stage-coloured header, into BOTH double-
 * buffer frames (docs/040: hifb is double buffered). */
static void draw(u32 pct, u32 stage) {
    if (pct > 100) pct = 100;
    u32 s = stage % 6;
    u32 done = COL_DONE[s], hdr = COL_HDR[s];
    u32 bar = (g_cols * pct) / 100;

    if (g_fb) {
        for (u32 f = 0; f < 2; f++) {
            volatile u32 *fr = g_fb + f * g_frame_words;
            for (u32 y = 0; y < g_rows; y++) {
                u32 row = y * g_cols;
                for (u32 x = 0; x < g_cols; x++)
                    fr[row + x] = (y < 40) ? hdr : ((x < bar) ? done : COL_TODO);
            }
        }
    } else {
        /* fallback: linear write() of alternating colour bands over whole smem */
        SC3(NR_lseek, g_fbfd, 0, 0);
        u32 remain = g_len, band = 0;
        while (remain) {
            u32 take = remain > CHUNK ? CHUNK : remain;
            u32 c = (band++ & 1) ? done : COL_TODO;
            u32 *w = (u32 *)g_chunk;
            for (u32 i = 0; i < take / 4; i++) w[i] = c;
            SC3(NR_write, g_fbfd, g_chunk, take);
            remain -= take;
        }
    }
}

/* Mount U-disk. Returns 1 if /usb/flash.manifest was flashed, 0 otherwise. */
static int auto_flash(void) {
    SC2(NR_mkdir, "/usb", 0755);
    long m = SC5(NR_mount, "/dev/block/sda1", "/usb", "vfat", 0, 0);
    if (m < 0) m = SC5(NR_mount, "/dev/sda1", "/usb", "vfat", 0, 0);
    if (m < 0) m = SC5(NR_mount, "/dev/block/sda1", "/usb", "msdos", 0, 0);

    long mf = SC3(NR_open, "/usb/flash.manifest", O_RDONLY, 0);
    if (mf < 0) return 0;                 /* no manifest -> display demo only */
    long n = SC3(NR_read, mf, g_man, (long)(sizeof(g_man) - 1));
    SC1(NR_close, mf);
    if (n <= 0) return 0;
    g_man[n] = 0;

    /* count lines */
    u32 total = 0;
    for (long i = 0; i < n; i++) if (g_man[i] == '\n') total++;
    if (!total) total = 1;

    long dev = SC3(NR_open, "/dev/block/mmcblk0", O_RDWR, 0);
    if (dev < 0) dev = SC3(NR_open, "/dev/mmcblk0", O_RDWR, 0);

    char *p = (char *)g_man, *end = (char *)g_man + n;
    u32 idx = 0;
    while (p < end) {
        while (p < end && (*p == ' ' || *p == '\t' || *p == '\r' || *p == '\n')) p++;
        if (p >= end || *p == '#') { while (p < end && *p != '\n') p++; continue; }
        char *ls = p; while (p < end && *p != '\n') p++;
        char *le = p; if (p < end) *p = 0;
        /* split line by whitespace */
        char *tok[3]; int nt = 0; char *q = ls;
        while (q < le && nt < 3) {
            while (q < le && (*q == ' ' || *q == '\t' || *q == '\r')) q++;
            if (q >= le) break;
            tok[nt++] = q;
            while (q < le && *q != ' ' && *q != '\t' && *q != '\r') q++;
            if (q < le) *q++ = 0;
        }
        u32 pct = (idx + 1) * 100 / total;
        draw(pct, idx); delay();
        if (nt >= 3 && dev >= 0) {
            u32 lba = hexval(tok[1], slen(tok[1]));
            u32 bytes = hexval(tok[2], slen(tok[2]));
            long in = SC3(NR_open, tok[0], O_RDONLY, 0);
            if (in >= 0) {
                SC3(NR_lseek, dev, (long)lba * 512, 0);
                u32 left = bytes;
                while (left) {
                    long want = left > CHUNK ? CHUNK : (long)left;
                    long got = SC3(NR_read, in, g_chunk, want);
                    if (got <= 0) break;
                    SC3(NR_write, dev, g_chunk, got);
                    left -= (u32)got;
                }
                SC1(NR_close, in);
                SC1(NR_fsync, dev);
            }
        }
        idx++;
        if (p < end) p++;
    }
    if (dev >= 0) SC1(NR_close, dev);
    return 1;
}

void _start(void) {
    fb_init();
    int flashed = auto_flash();

    /* Never return: keep fb0 open so hifb does not blank the panel. */
    if (flashed) {
        for (;;) {
            draw(100, 2); delay();          /* solid DONE */
            draw(100, 4); delay();          /* slow colour pulse = finished */
        }
    } else {
        u32 stage = 0;
        for (;;) {
            for (u32 pct = 0; pct <= 100; pct += 2) { draw(pct, stage); delay(); }
            stage = (stage + 1) % 6;
        }
    }
    /* not reached */
    SC1(NR_exit, 0);
    for (;;) ;
}
