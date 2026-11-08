/* =============================================================================
 * recovery-flasher/flasher.c
 * EC6108V9C / Hi3798MV100 -- stock-recovery-kernel based AUTO FLASHER
 * =============================================================================
 * WHAT THIS IS
 *   A freestanding ARM-EABI Linux userspace program that REPLACES
 *   /sbin/recovery inside the STOCK Android recovery ramdisk. We keep the
 *   stock 3.10 kernel (it owns the hifb/VO/HDMI drivers that light the panel
 *   and register /dev/graphics/fb0) and replace only the userland.
 *
 *   init.rc has `service recovery /sbin/recovery` + `class_start default`, so
 *   Android init execs it automatically -- NO menu, NO key, NO interaction.
 *
 * BUILD STAGE  (change exactly this to advance the plan)
 *   STAGE = 0 : PROBE. Write /usb/flasher.log with every environment fact,
 *               NEVER write eMMC. Verify U-disk mount, eMMC node, device names.
 *               Keeps the validated colour progress bar on screen.
 *   STAGE = 1 : real auto-flash from /usb/flash.manifest (community Ubuntu),
 *               progress bar + log, hold on completion, no reboot.
 *
 * FULLY AUTOMATIC (both stages, no interaction)
 *   1. open /dev/graphics/fb0, get geometry, mmap (fallback: write()).
 *   2. mkdir /usb; mount U-disk (/dev/block/sda1 vfat, several candidates).
 *      Kernel has vfat+usb-storage (kallsyms verified, docs/050 §9).
 *   3. write /usb/flasher.log line by line, fsync+sync so it survives a yank.
 *   4. STAGE0: log everything, touch nothing on eMMC.
 *      STAGE1: parse flash.manifest <src> <lba-hex> <bytes-hex>, raw-write
 *              /dev/block/mmcblk0 by absolute LBA, advance bar per item.
 *   5. Never exit (keep fb0 open: hifb blanks the panel on close, docs/040).
 *
 * SAFETY
 *   - STAGE0 performs ZERO eMMC writes. eMMC is only opened O_RDWR to test
 *     the node exists, then closed without any write/read of data.
 *   - Real writes (STAGE1) go to raw /dev/block/mmcblk0 by explicit LBA, so
 *     the Android 16-partition blkdevparts cmdline is irrelevant.
 *
 * BUILD (host clang, no cross-gcc, no libc, no sysroot):
 *   clang --target=armv7-unknown-linux-gnueabi -fuse-ld=lld -static -nostdlib \
 *     -ffreestanding -fno-builtin -fno-stack-protector \
 *     -fno-vectorize -fno-slp-vectorize -mfloat-abi=soft -O2 -o flasher flasher.c
 * ============================================================================= */

typedef unsigned int  u32;
typedef unsigned long ulong;
#define NULL ((void *)0)

#define STAGE 0   /* 0 = probe only (no eMMC writes); 1 = real auto-flash */

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
#define SC0(n)          sc6((n),0,0,0,0,0,0)
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
#define NR_sync      36
#define NR_mkdir     39
#define NR_mount     40
#define NR_ioctl     54
#define NR_fsync     118
#define NR_mmap2     192

#define O_RDONLY     0
#define O_WRONLY     1
#define O_RDWR       2
#define O_CREAT      0x40
#define O_TRUNC      0x200
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

/* recorded facts for the U-disk log */
static long g_fb0_rc, g_fb_fallback_rc, g_mmap_rc;
static long g_mkdir_rc;

static const u32 COL_DONE[6] = {
    0xFF00FF00, 0xFF00FFC0, 0xFF40FF40, 0xFF80FF00, 0xFFC0FF00, 0xFFFFFF00
};
static const u32 COL_HDR[6] = {
    0xFFFF0000, 0xFFFF8000, 0xFFFFFF00, 0xFF00FFFF, 0xFF0080FF, 0xFFFF00FF
};
#define COL_TODO 0xFF102040

/* ---- U-disk log (syscall only; fsync+sync so data survives a yank) ---- */
static int g_logfd = -1;
static void log_str(const char *s) {
    if (g_logfd >= 0) SC3(NR_write, g_logfd, s, slen(s));
}
static void log_hex(long v) {
    char b[11];
    const char *hx = "0123456789abcdef";
    u32 u = (u32)v;
    b[0] = '0'; b[1] = 'x';
    for (int i = 0; i < 8; i++) b[2+i] = hx[(u >> ((7-i)*4)) & 0xf];
    b[10] = '\n';
    if (g_logfd >= 0) SC3(NR_write, g_logfd, b, 11);
}
static void log_kv(const char *k, long v) { log_str(k); log_hex(v); }

static int fb_init(void) {
    g_fb0_rc = SC3(NR_open, "/dev/graphics/fb0", O_RDWR, 0);
    long fd = g_fb0_rc;
    g_fb_fallback_rc = -1;
    if (fd < 0) {
        g_fb_fallback_rc = SC3(NR_open, "/dev/fb0", O_RDWR, 0);
        fd = g_fb_fallback_rc;
    }
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

    g_mmap_rc = sc6(NR_mmap2, 0, (long)g_len, PROT_RW, MAP_SHARED, (long)g_fbfd, 0);
    /* Linux returns -errno as (unsigned)0xfffff001..0xffffffff on failure */
    if ((u32)g_mmap_rc >= 0xfffff001u) g_fb = NULL;              /* write() fallback */
    else g_fb = (volatile u32 *)g_mmap_rc;
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

/* ---- U-disk mount candidates (recovery.fstab: /dev/block/sda1 -> /usb) ---- */
typedef struct { const char *src; const char *fs; const char *label; } mtry_t;
static const mtry_t g_tries[] = {
    {"/dev/block/sda1",        "vfat",  "mount /dev/block/sda1 vfat   = "},
    {"/dev/block/sda1",        "msdos", "mount /dev/block/sda1 msdos  = "},
    {"/dev/sda1",              "vfat",  "mount /dev/sda1 vfat         = "},
    {"/dev/block/sda",         "vfat",  "mount /dev/block/sda vfat    = "},
    {"/mnt/sda/sda1",          "vfat",  "mount /mnt/sda/sda1 vfat     = "},
    {"/dev/block/mmcblk1p1",   "vfat",  "mount /dev/block/mmcblk1p1   = "},
};
#define NTRIES ((int)(sizeof(g_tries)/sizeof(g_tries[0])))
static long g_mrc[NTRIES];

static long udisk_mount(void) {
    g_mkdir_rc = SC2(NR_mkdir, "/usb", 0755);
    long rc = -1;
    /* ueventd may need a moment to create the nodes: two passes with a delay */
    for (int pass = 0; pass < 2 && rc < 0; pass++) {
        for (int i = 0; i < NTRIES; i++) {
            long r = SC5(NR_mount, g_tries[i].src, "/usb", g_tries[i].fs, 0, 0);
            g_mrc[i] = r;
            if (r >= 0 && rc < 0) rc = r;   /* first success wins */
        }
        if (rc < 0) delay();
    }
    return rc;
}

/* ---- STAGE 0 probe: write facts to U-disk, NEVER touch eMMC ---- */
static void probe(void) {
    fb_init();
    long mrc = udisk_mount();

    /* Open the log on the U-disk (create/truncate), then dump all facts. */
    long lfd = SC3(NR_open, "/usb/flasher.log",
                   O_WRONLY | O_CREAT | O_TRUNC, 0644);
    g_logfd = (int)lfd;

    log_str("== recovery-flasher STAGE0 PROBE ==\n");
    log_str("arch: armv7 32-bit ELF, freestanding syscall\n");
    log_kv("STAGE                         = ", STAGE);
    log_kv("open /dev/graphics/fb0 O_RDWR = ", g_fb0_rc);
    log_kv("open /dev/fb0 O_RDWR (fbk)    = ", g_fb_fallback_rc);
    log_kv("fb mmap2                      = ", g_mmap_rc);
    log_kv("fb smem_len                   = ", (long)g_len);
    log_kv("fb line_length                = ", (long)g_stride);
    log_kv("fb cols x rows                = ", (long)(g_cols * 65536u + (g_rows & 0xffff)));
    log_kv("mkdir /usb                    = ", g_mkdir_rc);
    for (int i = 0; i < NTRIES; i++) log_kv(g_tries[i].label, g_mrc[i]);
    log_kv("mount SELECTED (>=0 ok)       = ", mrc);
    log_kv("open /usb/flasher.log         = ", lfd);

    /* Can we READ the U-disk? recovery.img is on the U-disk root (bootm loads
       it). Open + read first 4 bytes; proves vfat read path works. */
    long img = SC3(NR_open, "/usb/recovery.img", O_RDONLY, 0);
    log_kv("open /usb/recovery.img        = ", img);
    if (img >= 0) {
        long got = SC3(NR_read, img, g_chunk, 4);
        log_kv("read recovery.img [0..3]      = ", got);
        log_kv("  first4 bytes (hex)          = ",
               (long)(got >= 4 ? rd32(g_chunk, 0) : 0));
        SC1(NR_close, img);
    }

    /* eMMC nodes: open O_RDWR to test existence/writability, CLOSE with NO
       write -- ZERO data touched. This answers "is mmcblk0 usable". */
    long mmc1 = SC3(NR_open, "/dev/block/mmcblk0", O_RDWR, 0);
    log_kv("open /dev/block/mmcblk0 O_RDWR= ", mmc1);
    if (mmc1 >= 0) SC1(NR_close, mmc1);
    long mmc2 = SC3(NR_open, "/dev/mmcblk0", O_RDWR, 0);
    log_kv("open /dev/mmcblk0 O_RDWR      = ", mmc2);
    if (mmc2 >= 0) SC1(NR_close, mmc2);
    long byname = SC3(NR_open,
        "/dev/block/platform/hi_mci.1/by-name/bootargs", O_RDONLY, 0);
    log_kv("open by-name/bootargs         = ", byname);
    if (byname >= 0) SC1(NR_close, byname);

    /* Did a manifest accidentally exist? (STAGE0 ignores it entirely.) */
    long mf = SC3(NR_open, "/usb/flash.manifest", O_RDONLY, 0);
    log_kv("open /usb/flash.manifest      = ", mf);
    if (mf >= 0) SC1(NR_close, mf);

    log_str("eMMC WRITES: NONE (STAGE0 probe)\n");
    log_str("== PROBE END, entering display loop ==\n");

    if (g_logfd >= 0) {
        SC1(NR_fsync, g_logfd);
        SC1(NR_close, g_logfd);
        g_logfd = -1;
    }
    SC0(NR_sync);               /* flush FAT metadata + data to the U-disk */
}

/* ---- STAGE 1 real auto-flash (kept for the next iteration) ---- */
__attribute__((unused))
static int auto_flash(void) {
    long m = SC5(NR_mount, "/dev/block/sda1", "/usb", "vfat", 0, 0);
    if (m < 0) m = SC5(NR_mount, "/dev/sda1", "/usb", "vfat", 0, 0);
    if (m < 0) m = SC5(NR_mount, "/dev/block/sda1", "/usb", "msdos", 0, 0);

    long mf = SC3(NR_open, "/usb/flash.manifest", O_RDONLY, 0);
    if (mf < 0) return 0;
    long n = SC3(NR_read, mf, g_man, (long)(sizeof(g_man) - 1));
    SC1(NR_close, mf);
    if (n <= 0) return 0;
    g_man[n] = 0;

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
#if STAGE == 0
    probe();                    /* writes /usb/flasher.log, ZERO eMMC writes */
    int flashed = 0;
#else
    fb_init();
    int flashed = auto_flash();
#endif

    /* Never return: keep fb0 open so hifb does not blank the panel. */
    if (flashed) {
        for (;;) {
            draw(100, 2); delay();
            draw(100, 4); delay();
        }
    } else {
        u32 stage = 0;
        for (;;) {
            for (u32 pct = 0; pct <= 100; pct += 2) { draw(pct, stage); delay(); }
            stage = (stage + 1) % 6;
        }
    }
    SC1(NR_exit, 0);            /* not reached */
    for (;;) ;
}
