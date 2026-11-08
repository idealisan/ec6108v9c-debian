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
 * SCREEN OUTPUT = BIG STATE NUMBER + ENGLISH ONE-LINER (5x7 ASCII font,
 *   embedded -- NO external library, freestanding). Numbers are precise to
 *   report; the English line spells out the error directly. Both use the same
 *   classic 5x7 dot-matrix glyphs (digits + A-Z + " -.:/%!?").
 *   The LAST status stays on screen forever (no reboot).
 *
 *   STATE CODES (held on the final one):
 *     1  BOOT OK                   2  MOUNT USB...
 *     3  USB MOUNT OK             4  MANIFEST OK
 *     5  FLASHING                 6  DONE NO REBOOT
 *     7  NO USB NODE (=no U-disk block node ever appeared / USB not enumerated)
 *     8  NO MANIFEST (display-only, safe)
 *     9  NO EMMC NODE
 *     70 NODE HERE MOUNT FAIL (=node appeared but every mount combo failed)
 *   While flashing, a growing PERCENT number (0..100) + "FLASHING" is shown;
 *   a rising number = actively writing. Completion returns to 6.
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
#define NR_access    33
#define NR_sync      36
#define NR_mkdir     39
#define NR_mount     40
#define NR_ioctl     54
#define NR_fsync     118
#define NR_nanosleep 162
#define NR_mmap2     192

/* ARM EABI: nanosleep(const struct timespec *req, struct timespec *rem) */
typedef struct { long tv_sec; long tv_nsec; } timespec_t;
static void sleep_sec(u32 s) {
    timespec_t ts; ts.tv_sec = (long)s; ts.tv_nsec = 0;
    SC2(NR_nanosleep, &ts, 0);
}
/* access(path, F_OK) -> 0 if the node exists */
static int path_exists(const char *p) {
    return SC2(NR_access, p, 0) >= 0;
}

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

/* Standard 5x7 ASCII dot-matrix font (the classic glcdfont/font5x7 data,
   embedded here so the freestanding ELF needs NO external library).
   Index order: "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ -.:/%!?"
   Each row's low 5 bits; bit4 = leftmost dot. */
static const unsigned char FONT[44][7] = {
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
    {0x0E,0x11,0x11,0x1F,0x11,0x11,0x11}, /* A */
    {0x1E,0x11,0x11,0x1E,0x11,0x11,0x1E}, /* B */
    {0x0E,0x11,0x10,0x10,0x10,0x11,0x0E}, /* C */
    {0x1E,0x11,0x11,0x11,0x11,0x11,0x1E}, /* D */
    {0x1F,0x10,0x10,0x1E,0x10,0x10,0x1F}, /* E */
    {0x1F,0x10,0x10,0x1E,0x10,0x10,0x10}, /* F */
    {0x0E,0x11,0x10,0x17,0x11,0x11,0x0F}, /* G */
    {0x11,0x11,0x11,0x1F,0x11,0x11,0x11}, /* H */
    {0x0E,0x04,0x04,0x04,0x04,0x04,0x0E}, /* I */
    {0x07,0x02,0x02,0x02,0x02,0x12,0x0C}, /* J */
    {0x11,0x12,0x14,0x18,0x14,0x12,0x11}, /* K */
    {0x10,0x10,0x10,0x10,0x10,0x10,0x1F}, /* L */
    {0x11,0x1B,0x15,0x15,0x11,0x11,0x11}, /* M */
    {0x11,0x19,0x15,0x13,0x11,0x11,0x11}, /* N */
    {0x0E,0x11,0x11,0x11,0x11,0x11,0x0E}, /* O */
    {0x1E,0x11,0x11,0x1E,0x10,0x10,0x10}, /* P */
    {0x0E,0x11,0x11,0x11,0x15,0x12,0x0D}, /* Q */
    {0x1E,0x11,0x11,0x1E,0x14,0x12,0x11}, /* R */
    {0x0F,0x10,0x10,0x0E,0x01,0x01,0x1E}, /* S */
    {0x1F,0x04,0x04,0x04,0x04,0x04,0x04}, /* T */
    {0x11,0x11,0x11,0x11,0x11,0x11,0x0E}, /* U */
    {0x11,0x11,0x11,0x11,0x11,0x0A,0x04}, /* V */
    {0x11,0x11,0x11,0x15,0x15,0x1B,0x11}, /* W */
    {0x11,0x11,0x0A,0x04,0x0A,0x11,0x11}, /* X */
    {0x11,0x11,0x0A,0x04,0x04,0x04,0x04}, /* Y */
    {0x1F,0x01,0x02,0x04,0x08,0x10,0x1F}, /* Z */
    {0x00,0x00,0x00,0x00,0x00,0x00,0x00}, /* space */
    {0x00,0x00,0x00,0x1F,0x00,0x00,0x00}, /* - */
    {0x00,0x00,0x00,0x00,0x00,0x0C,0x0C}, /* . */
    {0x00,0x04,0x04,0x00,0x04,0x04,0x00}, /* : */
    {0x01,0x02,0x02,0x04,0x08,0x08,0x10}, /* / */
    {0x19,0x1A,0x02,0x04,0x08,0x0B,0x13}, /* % */
    {0x04,0x04,0x04,0x04,0x04,0x00,0x04}, /* ! */
    {0x0E,0x11,0x01,0x02,0x04,0x00,0x04}, /* ? */
};
#define FONT_ORDER "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ -.:/%!?"
#define DW 5
#define DH 7

/* map an ASCII char to a FONT index (uppercase, '?' as fallback) */
static int glyph_index(char c) {
    if (c >= 'a' && c <= 'z') c -= 32;
    for (int i = 0; i < 44; i++) if (FONT_ORDER[i] == c) return i;
    return 43; /* '?' */
}

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

/* Draw one row of glyphs (indices into FONT) at (x0,y0) with dot-scale sc,
   colour fg, into BOTH frames. Clipped to framebuffer bounds. */
static void render_row(const unsigned char *idx, int n, u32 x0, u32 y0,
                       u32 sc, u32 fg) {
    if (!g_fb) return;
    u32 adv = (DW + 1) * sc;
    for (int i = 0; i < n; i++) {
        const unsigned char *glyph = FONT[idx[i]];
        u32 dx = x0 + (u32)i * adv;
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
                            fr[row + X] = fg;
                        }
                    }
                }
            }
        }
    }
}

/* Show a big centred decimal number (upper area). */
static void render_big_number(u32 n, u32 y0, u32 sc) {
    unsigned char d[8]; int nd = 0;
    if (n == 0) { d[nd++] = 0; }
    else {
        unsigned char tmp[8]; int k = 0; u32 t = n;
        while (t && k < 8) { tmp[k++] = (unsigned char)(t % 10); t /= 10; }
        while (k) d[nd++] = tmp[--k];
    }
    u32 adv = (DW + 1) * sc;
    u32 pic_w = (u32)nd * adv;
    u32 x0 = (g_cols > pic_w) ? (g_cols - pic_w) / 2 : 0;
    render_row(d, nd, x0, y0, sc, C_FG);
}

/* Show a short UPPERCASE message (lower area), auto-scaled to fit width. */
static void render_msg(const char *msg, u32 y0) {
    int len = slen(msg);
    if (len <= 0) return;
    unsigned char idx[64];
    if (len > 64) len = 64;
    for (int i = 0; i < len; i++) idx[i] = (unsigned char)glyph_index(msg[i]);
    u32 adv_dots = DW + 1;
    u32 by_w = (g_cols - 20) / ((u32)len * adv_dots + 1);
    u32 by_h = (g_rows - y0 - 4) / (DH + 1);
    u32 sc = by_w < by_h ? by_w : by_h;
    if (sc < 2) sc = 2;
    u32 pic_w = (u32)len * adv_dots * sc;
    u32 x0 = (g_cols > pic_w) ? (g_cols - pic_w) / 2 : 0;
    (void)adv_dots;
    render_row(idx, len, x0, y0, sc, C_FG);
}

/* Full status screen: big state number on top + English one-liner below. */
static void show_status(u32 code, const char *msg) {
    solid(C_BG);
    if (!g_fb) return;                        /* write fallback: solid only */
    u32 num_sc = g_rows / 16;                /* ~40% screen tall number */
    if (num_sc < 4) num_sc = 4;
    render_big_number(code, g_rows / 12, num_sc);   /* top area */
    render_msg(msg, g_rows * 62 / 100);             /* lower area, clear gap */
}

/* Hold a state (number + message) on screen for a visible moment. */
static void state(u32 code, const char *msg) {
    show_status(code, msg); delay(); delay();
}
/* Final state: keep showing the same status forever (no reboot). */
static void hold(u32 code, const char *msg) {
    for (;;) { show_status(code, msg); delay(); delay(); delay(); }
}

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

/* ---- U-disk mount, mirroring the STOCK fs_mgr (reverse-engineered) ----
   Teammate disassembled p03__sbin__recovery ensure_path_mounted():
     - sleep(5) first, then stat()/access() poll the device node ~10x with
       sleep(1) between, so USB enumeration / ueventd can create /dev/block/sda1;
     - fstab "auto" is NOT passed to the kernel: try vfat -> ext4 -> ntfs;
       mount flags 0xc04 (MS_NODEV|MS_NOATIME|MS_NODIRATIME);
     - fallback alternate node names sda1->sda, mmcblk1p1->mmcblk1;
     - read /proc/mounts first to avoid remount; mkdir(mountpoint,0755) before.
   We do the same, plus a few extra candidate nodes/fstypes ("多试试").
   g_node_seen tells us whether ANY U-disk block node ever appeared; used to
   split failure into code 7 (no node / USB not enumerated) vs 70 (node seen
   but every mount combination failed = fstype/flags problem).
------------------------------------------------------------------------- */
static const char *NODES[] = {
    "/dev/block/sda1", "/dev/block/sda",
    "/dev/block/mmcblk1p1", "/dev/block/mmcblk1",
    "/dev/sda1", "/dev/sda",
    "/mnt/sda/sda1",
};
#define NNODES ((int)(sizeof(NODES)/sizeof(NODES[0])))
static const char *FSTYPES[] = {
    "vfat", "ext4", "ntfs", "msdos", "fat", "auto", "exfat", "fuse"
};
#define NFST ((int)(sizeof(FSTYPES)/sizeof(FSTYPES[0])))
#define MNT_FLAGS 0xc04u      /* MS_NODEV|MS_NOATIME|MS_NODIRATIME */
static int  g_node_seen = 0;  /* did any candidate node ever appear? */
static long g_last_mnt_rc = -1;

/* read /proc/mounts to see if /usb is already mounted by someone else */
static int usb_already_mounted(void) {
    long fd = SC3(NR_open, "/proc/mounts", O_RDONLY, 0);
    if (fd < 0) return 0;
    long n = SC3(NR_read, fd, g_chunk, CHUNK - 1);
    SC1(NR_close, fd);
    if (n <= 0) return 0;
    g_chunk[n] = 0;
    /* look for " /usb " token */
    for (long i = 0; i + 5 < n; i++)
        if (g_chunk[i]==' ' && g_chunk[i+1]=='/' && g_chunk[i+2]=='u' &&
            g_chunk[i+3]=='s' && g_chunk[i+4]=='b' && g_chunk[i+5]==' ')
            return 1;
    return 0;
}

/* try all fstype/flags/data combos on one node; return 0 on success */
static long try_mount(const char *node) {
    static const char *DATA[] = { "", "iocharset=utf8", "utf8,uid=0,gid=0" };
#define NDATA ((int)(sizeof(DATA)/sizeof(DATA[0])))
    static const u32 FLAGS[] = { MNT_FLAGS, 0u, 0xc04u | 1u }; /* +MS_RDONLY variant */
#define NFLAG ((int)(sizeof(FLAGS)/sizeof(FLAGS[0])))
    for (int f = 0; f < NFST; f++)
        for (int fl = 0; fl < NFLAG; fl++)
            for (int dd = 0; dd < NDATA; dd++) {
                long r = SC5(NR_mount, node, "/usb", FSTYPES[f],
                             FLAGS[fl], DATA[dd]);
                if (r >= 0) return 0;
                g_last_mnt_rc = r;
            }
    return -1;
}

static long udisk_mount(void) {
    SC2(NR_mkdir, "/usb", 0755);
    /* fast path: already mounted (e.g. by init/fs_mgr) */
    if (usb_already_mounted()) { g_node_seen = 1; return 0; }
    if (path_exists("/usb/recovery.img")) { g_node_seen = 1; return 0; }

    /* stock behaviour: wait 5s for USB enumeration before probing nodes */
    sleep_sec(5);

    /* ~12 passes of stat polling with 1s sleeps, like fs_mgr wait_for_file */
    for (int pass = 0; pass < 12; pass++) {
        for (int i = 0; i < NNODES; i++) {
            if (!path_exists(NODES[i])) continue;
            g_node_seen = 1;
            if (try_mount(NODES[i]) >= 0) return 0;
        }
        /* re-check "already mounted" each pass */
        if (usb_already_mounted()) return 0;
        sleep_sec(1);
    }
    return -1;
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
        show_status(pct_before, "FLASHING");
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
        show_status(idx * 100 / total, "FLASHING");
        delay();
        if (p < end) p++;
    }
    SC1(NR_close, dev);
    show_status(100, "FLASH DONE");
    return (int)flashed;
}

void _start(void) {
    fb_init();
    state(1, "BOOT OK");

    state(2, "MOUNT USB...");
    long mrc = udisk_mount();

    long lfd = SC3(NR_open, "/usb/flasher.log", O_WRONLY|O_CREAT|O_TRUNC, 0644);
    g_logfd = (int)lfd;
    log_str("== recovery-flasher stage1 (digits+text) ==\n");
    log_kv("fb smem_len = ", (long)g_len);
    log_kv("fb stride   = ", (long)g_stride);
    log_kv("mount /usb  = ", mrc);
    log_kv("node_seen   = ", g_node_seen);
    log_kv("last_mnt_rc = ", g_last_mnt_rc);
    log_kv("open log    = ", lfd);
    { long e = SC3(NR_open, "/dev/block/mmcblk0", O_RDONLY, 0);
      log_kv("mmcblk0 node= ", e >= 0 ? 0 : -1);
      if (e >= 0) SC1(NR_close, e); }

    u32 final_code;
    const char *final_msg;
    if (mrc < 0) {
        if (!g_node_seen) { final_code = 7;  final_msg = "NO USB NODE"; }
        else              { final_code = 70; final_msg = "NODE HERE MOUNT FAIL"; }
        log_str("RESULT: U-disk mount failed\n");
    } else {
        state(3, "USB MOUNT OK");
        long chk = SC3(NR_open, "/usb/flash.manifest", O_RDONLY, 0);
        if (chk < 0) {
            final_code = 8; final_msg = "NO MANIFEST";
            log_str("RESULT: no flash.manifest (code 8)\n");
        } else {
            SC1(NR_close, chk);
            state(4, "MANIFEST OK");
            log_str("RESULT: manifest found, flashing\n");
            state(5, "FLASHING");
            int r = do_flash();
            log_kv("flashed items = ", r);
            if (r == -2) { final_code = 9; final_msg = "NO EMMC NODE"; }
            else         { final_code = 6; final_msg = "DONE NO REBOOT"; }
        }
    }

    if (g_logfd >= 0) {
        SC1(NR_fsync, g_logfd);
        SC1(NR_close, g_logfd);
        g_logfd = -1;
    }
    SC0(NR_sync);

    hold(final_code, final_msg);       /* number + English message, no reboot */
    SC1(NR_exit, 0);                  /* not reached */
}
