/* =============================================================================
 * recovery-flasher/flasher.c
 * EC6108V9C / Hi3798MV100 -- stock-recovery-kernel based AUTO FLASHER
 * =============================================================================
 * WHAT THIS IS
 *   A freestanding ARM-EABI Linux userspace program that REPLACES
 *   /sbin/recovery inside the STOCK Android recovery ramdisk. We keep the
 *   stock 3.10 kernel (it owns the hifb/VO/HDMI drivers that light the panel
 *   and register /dev/graphics/fb0) and replace only the userland. init.rc has
 *   `service recovery /sbin/recovery` + `class_start default`, so Android init
 *   execs it automatically -- NO menu, NO key, NO interaction.
 *
 * SCREEN OUTPUT = LARGE DOT-MATRIX DIGITS (not colours).
 *   The user cannot describe arbitrary colours precisely, but CAN read a
 *   number. So every state/result is shown as a big centred decimal number
 *   (5x7 font, scaled up). The LAST number stays on screen forever (no reboot),
 *   so a single flash tells us exactly where it stopped.
 *
 *   STATE CODES (one digit, held on the final one):
 *     1  boot, fb0 opened          2  mounting U-disk
 *     3  U-disk mount OK           4  flash.manifest found
 *     5  flashing                  6  DONE (no reboot)
 *     7  U-disk mount FAILED       8  no manifest (display-only, safe)
 *     9  eMMC node cannot open
 *   While flashing, the screen shows a growing PERCENT number (0..100); a
 *   rising number = actively writing. Completion returns to 6.
 *
 * U-DISK LOG (best-effort, merged -- not a separate round): if /usb mounts,
 *   write /usb/flasher.log line-by-line, fsync+sync. If it does not mount, the
 *   on-screen number already carries the diagnosis.
 *
 * REAL FLASH ENGINE: /usb/flash.manifest, one item per line:
 *      <src-full-path> <dest-lba-hex> <byte-count-hex> <kind>
 *   kind = R (raw: copy <byte-count> bytes verbatim to LBA)
 *        = S (Android sparse: decode 28B file hdr + 12B chunk hdrs; RAW chunks
 *             written blockwise, DONT_CARE/FILL handled; <byte-count> unused)
 *   Writes go to RAW /dev/block/mmcblk0 by absolute LBA, so the Android
 *   16-partition blkdevparts cmdline is irrelevant. NO manifest => zero writes.
 *
 * SAFETY: eMMC written ONLY when flash.manifest exists; otherwise display-only.
 *   Sparse DONT_CARE skipped by lseek (no zeroing of unrelated sectors).
 *   p1/fastboot never touched; same shorted flow is always re-flashable.
 *
 * BUILD (host clang, no cross-gcc/libc/sysroot, no NEON):
 *   clang --target=armv7-unknown-linux-gnueabi -fuse-ld=lld -static -nostdlib \
 *     -ffreestanding -fno-builtin -fno-stack-protector \
 *     -fno-vectorize -fno-slp-vectorize -mfloat-abi=soft -O2 -o flasher flasher.c
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
#define SEEK_CUR     1
#define CHUNK        (64 * 1024)
#define SPARSE_MAGIC 0xed26ff3au
#define CHUNK_RAW       0xCAC1
#define CHUNK_FILL      0xCAC2
#define CHUNK_DONT_CARE 0xCAC3
#define CHUNK_CRC32     0xCAC4

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
static void delay(void) { volatile unsigned long i; for (i = 0; i < 0x600000UL; i++) ; }

/* ---- framebuffer state ---- */
static volatile u32 *g_fb;
static u32 g_len, g_stride, g_rows, g_cols, g_frame_words;
static int g_fbfd = -1;
static unsigned char g_chunk[CHUNK];          /* .bss, zero-filled by loader */
static unsigned char g_man[8192];

#define C_BG   0xFF101830u    /* dark background */
#define C_FG   0xFFFFFFFFu    /* bright white digits */

/* 5x7 dot-matrix font for digits 0..9; each row's low 5 bits, bit4 = leftmost */
static const unsigned char DIGITS[10][7] = {
    {0x0E,0x11,0x13,0x15,0x19,0x11,0x0E}, /* 0 */
    {0x04,0x0C,0x04,0x04,0x04,0x04,0x0E}, /* 1 */
    {0x0E,0x11,0x01,0x02,0x04,0x08,0x1F}, /* 2 */
    {0x1F,0x02,0x04,0x02,0x01,0x11,0x0E}, /* 3 */
    {0x02,0x06,0x0A,0x12,0x1F,0x02,0x02}, /* 4 */
    {0x1F,0x10,0x1E,0x01,0x01,0x11,0x0E}, /* 5 */
    {0x06,0x08,0x10,0x1E,0x11,0x11,0x0E}, /* 6 */
    {0x1F,0x01,0x02,0x04,0x08,0x08,0x08}, /* 7 */
    {0x0E,0x11,0x11,0x0E,0x11,0x11,0x0E}, /* 8 */
    {0x0E,0x11,0x11,0x0F,0x01,0x02,0x0C}, /* 9 */
};
#define DW 5
#define DH 7

static int fb_init(void) {
    long fd = SC3(NR_open, "/dev/graphics/fb0", O_RDWR, 0);
    if (fd < 0) fd = SC3(NR_open, "/dev/fb0", O_RDWR, 0);
    if (fd < 0) return -1;
    g_fbfd = (int)fd;
    unsigned char var[256]; unsigned char fix[256];
    for (int i = 0; i < 256; i++) { var[i] = 0; fix[i] = 0; }
    SC3(NR_ioctl, g_fbfd, FBIOGET_VSCREENINFO, var);
    SC3(NR_ioctl, g_fbfd, FBIOGET_FSCREENINFO, fix);
    u32 xres = rd32(var, 0), yres = rd32(var, 4), bpp = rd32(var, 24);
    if (!bpp || bpp > 32) bpp = 32;
    if (!xres) xres = 1920;
    if (!yres) yres = 1080;
    g_len = rd32(fix, 20);
    if (!g_len) g_len = xres * yres * (bpp / 8) * 2;
    g_stride = rd32(fix, 44);
    if (g_stride < 64 || g_stride > 32768) g_stride = xres * (bpp / 8);
    g_frame_words = (g_len / 2) / 4;
    g_cols = g_stride / 4;
    g_rows = (g_len / 2) / (g_stride ? g_stride : 7680);
    if (!g_cols) g_cols = 1920;
    if (!g_rows) g_rows = 1080;
    long m = sc6(NR_mmap2, 0, (long)g_len, PROT_RW, MAP_SHARED, (long)g_fbfd, 0);
    if ((u32)m >= 0xfffff001u) g_fb = NULL;
    else g_fb = (volatile u32 *)m;
    return 0;
}

/* Fill BOTH double-buffer frames with one solid colour. */
static void solid(u32 color) {
    if (g_fb) {
        for (u32 f = 0; f < 2; f++) {
            volatile u32 *fr = g_fb + f * g_frame_words;
            for (u32 y = 0; y < g_rows; y++) {
                u32 row = y * g_cols;
                for (u32 x = 0; x < g_cols; x++) fr[row + x] = color;
            }
        }
    } else {
        SC3(NR_lseek, g_fbfd, 0, 0);
        u32 remain = g_len;
        u32 *w = (u32 *)g_chunk;
        for (u32 i = 0; i < CHUNK / 4; i++) w[i] = color;
        while (remain) {
            u32 take = remain > CHUNK ? CHUNK : remain;
            SC3(NR_write, g_fbfd, g_chunk, take);
            remain -= take;
        }
    }
}

/* Show a big centred decimal number `n` on BOTH frames. Digits only, no text.
   Scale is chosen so the number always fits the framebuffer. If mmap is
   unavailable we still paint a solid frame (write fallback) so the screen
   is never black; the digits need the mmap path (already validated on HW). */
static void show_number(u32 n) {
    /* decimal digits (most significant first) */
    unsigned char d[8]; int nd = 0;
    if (n == 0) { d[nd++] = 0; }
    else {
        unsigned char tmp[8]; int k = 0;
        u32 t = n;
        while (t && k < 8) { tmp[k++] = (unsigned char)(t % 10); t /= 10; }
        while (k) d[nd++] = tmp[--k];
    }
    u32 gap = 1;                              /* in dots */
    u32 adv_dots = DW + gap;
    u32 total_dots = (u32)nd * adv_dots;      /* approximate width in dots */
    u32 by_h = g_rows / (DH + 2);
    u32 by_w = (g_cols - 20) / (total_dots + 1);
    u32 sc = by_h < by_w ? by_h : by_w;
    if (sc < 2) sc = 2;
    u32 digit_adv = adv_dots * sc;
    u32 pic_w = (u32)nd * digit_adv;
    u32 x0 = (g_cols > pic_w) ? (g_cols - pic_w) / 2 : 0;
    u32 y0 = (g_rows > DH * sc) ? (g_rows - DH * sc) / 2 : 0;

    solid(C_BG);
    if (!g_fb) return;                        /* write fallback: solid only */
    for (int i = 0; i < nd; i++) {
        const unsigned char *glyph = DIGITS[d[i]];
        u32 dx = x0 + (u32)i * digit_adv;
        for (u32 r = 0; r < DH; r++) {
            unsigned char bits = glyph[r];
            for (u32 c = 0; c < DW; c++) {
                if (!(bits & (1u << (4 - c)))) continue;
                u32 px = dx + c * sc, py = y0 + r * sc;
                for (u32 f = 0; f < 2; f++) {
                    volatile u32 *fr = g_fb + f * g_frame_words;
                    for (u32 yy = 0; yy < sc; yy++) {
                        u32 Y = py + yy; if (Y >= g_rows) break;
                        u32 row = Y * g_cols;
                        for (u32 xx = 0; xx < sc; xx++) {
                            u32 X = px + xx; if (X >= g_cols) break;
                            fr[row + X] = C_FG;
                        }
                    }
                }
            }
        }
    }
}

/* Hold a state number on screen for a visible moment. */
static void state(u32 code) { show_number(code); delay(); delay(); }
/* Final state: keep showing the same number forever (no reboot). */
static void hold(u32 code) { for (;;) { show_number(code); delay(); delay(); delay(); } }

/* ---- U-disk log (best-effort) ---- */
static int g_logfd = -1;
static void log_str(const char *s) {
    if (g_logfd >= 0) SC3(NR_write, g_logfd, s, slen(s));
}
static void log_hex(long v) {
    char b[11]; const char *hx = "0123456789abcdef"; u32 u = (u32)v;
    b[0] = '0'; b[1] = 'x';
    for (int i = 0; i < 8; i++) b[2+i] = hx[(u >> ((7-i)*4)) & 0xf];
    b[10] = '\n';
    if (g_logfd >= 0) SC3(NR_write, g_logfd, b, 11);
}
static void log_kv(const char *k, long v) { log_str(k); log_hex(v); }

/* ---- U-disk mount candidates ---- */
typedef struct { const char *src; const char *fs; } mtry_t;
static const mtry_t g_tries[] = {
    {"/dev/block/sda1",      "vfat"},
    {"/dev/block/sda1",      "msdos"},
    {"/dev/sda1",            "vfat"},
    {"/dev/block/sda",       "vfat"},
    {"/mnt/sda/sda1",        "vfat"},
    {"/dev/block/mmcblk1p1", "vfat"},
};
#define NTRIES ((int)(sizeof(g_tries)/sizeof(g_tries[0])))

static long udisk_mount(void) {
    SC2(NR_mkdir, "/usb", 0755);
    long rc = -1;
    for (int pass = 0; pass < 3 && rc < 0; pass++) {
        for (int i = 0; i < NTRIES; i++) {
            long r = SC5(NR_mount, g_tries[i].src, "/usb", g_tries[i].fs, 0, 0);
            if (r >= 0 && rc < 0) rc = r;
        }
        if (rc < 0) delay();
    }
    return rc;
}

/* Write `bytes` raw bytes from `in` to `dev` at LBA `lba`. */
static u32 write_raw(long dev, long in, u32 lba, u32 bytes) {
    SC3(NR_lseek, dev, (long)lba * 512, 0);
    u32 left = bytes, done = 0;
    while (left) {
        long want = left > CHUNK ? CHUNK : (long)left;
        long got = SC3(NR_read, in, g_chunk, want);
        if (got <= 0) break;
        SC3(NR_write, dev, g_chunk, got);
        left -= (u32)got; done += (u32)got;
    }
    return done;
}

/* Decode Android sparse from `in`, write to `dev` at LBA `lba`.
   RAW=write payload; FILL=emit repeated dword; DONT_CARE/CRC=skip by lseek.
   Returns logically-covered bytes. */
static u32 write_sparse(long dev, long in, u32 lba) {
    unsigned char hdr[28];
    if (SC3(NR_read, in, hdr, 28) != 28) return 0;
    if (rd32(hdr, 0) != SPARSE_MAGIC) return 0;
    u32 blk_sz = rd32(hdr, 12);
    u32 total_chunks = rd32(hdr, 20);
    if (!blk_sz) blk_sz = 4096;
    u32 cur_lba = lba, covered = 0;
    for (u32 ci = 0; ci < total_chunks; ci++) {
        unsigned char ch[12];
        if (SC3(NR_read, in, ch, 12) != 12) break;
        u32 type = (u32)ch[0] | ((u32)ch[1] << 8);
        u32 nblk = rd32(ch, 4);
        u32 tsz  = rd32(ch, 8);
        u32 payload = tsz >= 12 ? tsz - 12 : 0;
        u32 span = nblk * blk_sz;
        if (type == CHUNK_RAW) {
            SC3(NR_lseek, dev, (long)cur_lba * 512, 0);
            u32 left = payload;
            while (left) {
                long want = left > CHUNK ? CHUNK : (long)left;
                long got = SC3(NR_read, in, g_chunk, want);
                if (got <= 0) break;
                SC3(NR_write, dev, g_chunk, got);
                left -= (u32)got;
            }
        } else if (type == CHUNK_FILL) {
            unsigned char fill[4];
            long fr = SC3(NR_read, in, fill, 4);
            if (fr != 4) { /* keep stream aligned below */ }
            u32 fv = rd32(fill, 0);
            u32 *w = (u32 *)g_chunk;
            for (u32 i = 0; i < CHUNK / 4; i++) w[i] = fv;
            SC3(NR_lseek, dev, (long)cur_lba * 512, 0);
            u32 left = span;
            while (left) {
                u32 take = left > CHUNK ? CHUNK : left;
                SC3(NR_write, dev, g_chunk, take);
                left -= take;
            }
        } else {
            if (payload) SC3(NR_lseek, in, (long)payload, SEEK_CUR);
        }
        cur_lba += span / 512;
        covered += span;
    }
    return covered;
}

/* Parse flash.manifest and flash every item; shows a growing percent number.
   Returns #flashed, -1 if manifest/eMMC unavailable. */
static int do_flash(void) {
    long mf = SC3(NR_open, "/usb/flash.manifest", O_RDONLY, 0);
    if (mf < 0) return -1;
    long n = SC3(NR_read, mf, g_man, (long)(sizeof(g_man) - 1));
    SC1(NR_close, mf);
    if (n <= 0) return -1;
    g_man[n] = 0;
    u32 total = 0;
    for (long i = 0; i < n; i++) if (g_man[i] == '\n') total++;
    if (!total) total = 1;

    long dev = SC3(NR_open, "/dev/block/mmcblk0", O_RDWR, 0);
    if (dev < 0) dev = SC3(NR_open, "/dev/mmcblk0", O_RDWR, 0);
    if (dev < 0) return -2;

    char *p = (char *)g_man, *end = (char *)g_man + n;
    u32 idx = 0, flashed = 0;
    while (p < end) {
        while (p < end && (*p==' '||*p=='\t'||*p=='\r'||*p=='\n')) p++;
        if (p >= end || *p == '#') { while (p < end && *p != '\n') p++; continue; }
        char *ls = p; while (p < end && *p != '\n') p++;
        char *le = p; if (p < end) *p = 0;
        char *tok[4]; int nt = 0; char *q = ls;
        while (q < le && nt < 4) {
            while (q < le && (*q==' '||*q=='\t'||*q=='\r')) q++;
            if (q >= le) break;
            tok[nt++] = q;
            while (q < le && *q!=' ' && *q!='\t' && *q!='\r') q++;
            if (q < le) *q++ = 0;
        }
        u32 pct_before = idx * 100 / total;
        show_number(pct_before);
        if (nt >= 2) {
            u32 lba = hexval(tok[1], slen(tok[1]));
            u32 bytes = (nt >= 3) ? hexval(tok[2], slen(tok[2])) : 0;
            char kind = (nt >= 4) ? tok[3][0] : 'R';
            long in = SC3(NR_open, tok[0], O_RDONLY, 0);
            if (in >= 0) {
                u32 wrote;
                if (kind == 'S') wrote = write_sparse(dev, in, lba);
                else            wrote = write_raw(dev, in, lba, bytes);
                log_kv("  wrote bytes = ", (long)wrote);
                SC1(NR_close, in);
                SC1(NR_fsync, dev);
                flashed++;
            }
        }
        idx++;
        show_number(idx * 100 / total);
        delay();
        if (p < end) p++;
    }
    SC1(NR_close, dev);
    show_number(100);
    return (int)flashed;
}

void _start(void) {
    fb_init();
    state(1);                          /* boot, fb0 OK */

    state(2);                          /* mounting U-disk */
    long mrc = udisk_mount();

    long lfd = SC3(NR_open, "/usb/flasher.log", O_WRONLY|O_CREAT|O_TRUNC, 0644);
    g_logfd = (int)lfd;
    log_str("== recovery-flasher stage1 (digits) ==\n");
    log_kv("fb smem_len = ", (long)g_len);
    log_kv("fb stride   = ", (long)g_stride);
    log_kv("mount /usb  = ", mrc);
    log_kv("open log    = ", lfd);
    { long e = SC3(NR_open, "/dev/block/mmcblk0", O_RDONLY, 0);
      log_kv("mmcblk0 node= ", e >= 0 ? 0 : -1);
      if (e >= 0) SC1(NR_close, e); }

    u32 final_code;
    if (mrc < 0) {
        final_code = 7;                /* mount FAILED */
        log_str("RESULT: U-disk mount failed (code 7)\n");
    } else {
        state(3);                      /* mount OK */
        long chk = SC3(NR_open, "/usb/flash.manifest", O_RDONLY, 0);
        if (chk < 0) {
            final_code = 8;            /* no manifest, display-only */
            log_str("RESULT: no flash.manifest (code 8)\n");
        } else {
            SC1(NR_close, chk);
            state(4);                  /* manifest found */
            log_str("RESULT: manifest found, flashing\n");
            state(5);                  /* flashing */
            int r = do_flash();
            log_kv("flashed items = ", r);
            final_code = (r == -2) ? 9 : 6;   /* 9 = eMMC node absent, 6 = DONE */
        }
    }

    if (g_logfd >= 0) {
        SC1(NR_fsync, g_logfd);
        SC1(NR_close, g_logfd);
        g_logfd = -1;
    }
    SC0(NR_sync);

    hold(final_code);                  /* keep showing the number, no reboot */
    SC1(NR_exit, 0);                  /* not reached */
}
