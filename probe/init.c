/* Freestanding init for the EC6108V9C display probe.
 *
 * Runs as PID 1 inside a tiny initramfs that is packaged next to the STOCK
 * 3.10 kernel from p11. It mounts devtmpfs, finds the hifb framebuffer and
 * paints the screen - so "the box is running our kernel" becomes visible on
 * the TV instead of being guessed from a dark screen.
 *
 * No libc: raw ARM EABI syscalls only, so the binary is a few KB and needs
 * nothing else in the initramfs.
 */
typedef unsigned int u32;
typedef int i32;

#define SYS_exit        1
#define SYS_write       4
#define SYS_open        5
#define SYS_close       6
#define SYS_ioctl       54
#define SYS_mount       21
#define SYS_mkdir       39
#define SYS_nanosleep   162
#define SYS_mmap2       192
#define SYS_reboot      88

#define FBIOGET_VSCREENINFO 0x4600
#define FBIOGET_FSCREENINFO 0x4602

#define O_RDWR 2
#define PROT_RW 3
#define MAP_SHARED 1

static inline i32 syscall3(i32 n, i32 a, i32 b, i32 c)
{
    register i32 r7 __asm__("r7") = n;
    register i32 r0 __asm__("r0") = a;
    register i32 r1 __asm__("r1") = b;
    register i32 r2 __asm__("r2") = c;
    __asm__ volatile("svc #0" : "+r"(r0) : "r"(r7), "r"(r1), "r"(r2) : "memory");
    return r0;
}

static inline i32 syscall6(i32 n, i32 a, i32 b, i32 c, i32 d, i32 e, i32 f)
{
    register i32 r7 __asm__("r7") = n;
    register i32 r0 __asm__("r0") = a;
    register i32 r1 __asm__("r1") = b;
    register i32 r2 __asm__("r2") = c;
    register i32 r3 __asm__("r3") = d;
    register i32 r4 __asm__("r4") = e;
    register i32 r5 __asm__("r5") = f;
    __asm__ volatile("svc #0" : "+r"(r0)
                     : "r"(r7), "r"(r1), "r"(r2), "r"(r3), "r"(r4), "r"(r5) : "memory");
    return r0;
}

static inline i32 syscall5(i32 n, i32 a, i32 b, i32 c, i32 d, i32 e)
{
    register i32 r7 __asm__("r7") = n;
    register i32 r0 __asm__("r0") = a;
    register i32 r1 __asm__("r1") = b;
    register i32 r2 __asm__("r2") = c;
    register i32 r3 __asm__("r3") = d;
    register i32 r4 __asm__("r4") = e;
    __asm__ volatile("svc #0" : "+r"(r0)
                     : "r"(r7), "r"(r1), "r"(r2), "r"(r3), "r"(r4) : "memory");
    return r0;
}

struct fb_bitfield { u32 offset, length, msb_right; };

struct fb_var_screeninfo {
    u32 xres, yres, xres_virtual, yres_virtual;
    u32 xoffset, yoffset;
    u32 bits_per_pixel, grayscale;
    struct fb_bitfield red, green, blue, transp;
    u32 nonstd, activate, height, width, accel_flags;
    u32 pixclock, left_margin, right_margin, upper_margin, lower_margin;
    u32 hsync_len, vsync_len, sync, vmode, rotate, colorspace;
};

struct fb_fix_screeninfo {
    char id[16];
    unsigned long smem_start;
    u32 smem_len;
    u32 type, type_aux, visual;
    u32 xpanstep, ypanstep, ywrapstep;
    u32 line_length;
    unsigned long mmio_start;
    u32 mmio_len, accel;
    u32 capabilities;
};

static int slen(const char *s)
{
    int n = 0;
    while (s[n]) n++;
    return n;
}

static void puts_buf(char *dst, const char *s, int *pos, int max)
{
    while (*s && *pos < max) dst[(*pos)++] = *s++;
}

static void sleep_ms(u32 ms)
{
    struct { u32 sec, nsec; } ts;
    ts.sec = ms / 1000;
    ts.nsec = (ms % 1000) * 1000000u;
    syscall3(SYS_nanosleep, (i32)&ts, 0, 0);
}

/* 5x7 column font, bit0 = top row. Only the glyphs this probe needs. */
struct glyph { char c; unsigned char col[5]; };
static const struct glyph FONT[] = {
    {'L', {0x7F, 0x40, 0x40, 0x40, 0x40}},
    {'I', {0x00, 0x41, 0x7F, 0x41, 0x00}},
    {'N', {0x7F, 0x02, 0x04, 0x08, 0x7F}},
    {'U', {0x3F, 0x40, 0x40, 0x40, 0x3F}},
    {'X', {0x63, 0x14, 0x08, 0x14, 0x63}},
    {'P', {0x7F, 0x09, 0x09, 0x09, 0x06}},
    {'R', {0x7F, 0x09, 0x19, 0x29, 0x46}},
    {'O', {0x3E, 0x41, 0x41, 0x41, 0x3E}},
    {'B', {0x7F, 0x49, 0x49, 0x49, 0x36}},
    {'E', {0x7F, 0x49, 0x49, 0x49, 0x41}},
    {'K', {0x7F, 0x08, 0x14, 0x22, 0x41}},
    {' ', {0x00, 0x00, 0x00, 0x00, 0x00}},
    {0, {0, 0, 0, 0, 0}}
};

static const struct glyph *find_glyph(char c)
{
    int i;
    for (i = 0; FONT[i].c; i++)
        if (FONT[i].c == c) return &FONT[i];
    return &FONT[11];
}

static u32 pack_color(u32 bpp, u32 rgb, struct fb_var_screeninfo *var, int fg)
{
    u32 r = fg ? ((rgb >> 16) & 0xff) : 0;
    u32 g = fg ? ((rgb >> 8) & 0xff) : 0;
    u32 b = fg ? (rgb & 0xff) : 0;
    if (bpp == 16)
        return ((r >> 3) << 11) | ((g >> 2) << 5) | (b >> 3);
    return 0xff000000u | (r << 16) | (g << 8) | b;
}

static void fill(unsigned char *fb, struct fb_fix_screeninfo *fix,
                 struct fb_var_screeninfo *var, u32 color)
{
    u32 x, y;
    for (y = 0; y < var->yres; y++) {
        unsigned char *row = fb + (unsigned long)y * fix->line_length;
        for (x = 0; x < var->xres; x++) {
            if (var->bits_per_pixel == 16)
                ((unsigned short *)row)[x] = (unsigned short)color;
            else
                ((u32 *)row)[x] = color;
        }
    }
}

static void draw_text(unsigned char *fb, struct fb_fix_screeninfo *fix,
                      struct fb_var_screeninfo *var, const char *s,
                      int ox, int oy, int scale, u32 color)
{
    int i;
    for (i = 0; s[i]; i++) {
        const struct glyph *g = find_glyph(s[i]);
        int cx, cy;
        for (cx = 0; cx < 5; cx++) {
            for (cy = 0; cy < 7; cy++) {
                if (!(g->col[cx] & (1 << cy))) continue;
                int px, py;
                for (py = 0; py < scale; py++) {
                    for (px = 0; px < scale; px++) {
                        int x = ox + (i * 6 + cx) * scale + px;
                        int y = oy + cy * scale + py;
                        unsigned char *row;
                        if (x < 0 || y < 0 || (u32)x >= var->xres || (u32)y >= var->yres)
                            continue;
                        row = fb + (unsigned long)y * fix->line_length;
                        if (var->bits_per_pixel == 16)
                            ((unsigned short *)row)[x] = (unsigned short)color;
                        else
                            ((u32 *)row)[x] = color;
                    }
                }
            }
        }
    }
}

static const char *CANDIDATES[] = {
    "/dev/graphics/fb0", "/dev/graphics/fb1",
    "/dev/fb0", "/dev/fb1", 0
};

void _start(void)
{
    struct fb_fix_screeninfo fix;
    struct fb_var_screeninfo var;
    unsigned char *fb;
    int fd = -1, i, pass;

    syscall3(SYS_mkdir, (i32)"/dev", 0755, 0);
    syscall5(SYS_mount, (i32)"devtmpfs", (i32)"/dev", (i32)"devtmpfs", 0, 0);

    for (pass = 0; pass < 40 && fd < 0; pass++) {
        for (i = 0; CANDIDATES[i]; i++) {
            fd = syscall3(SYS_open, (i32)CANDIDATES[i], O_RDWR, 0);
            if (fd >= 0) break;
        }
        if (fd < 0) sleep_ms(500);
    }

    if (fd < 0) {
        for (;;) sleep_ms(1000);
    }

    syscall3(SYS_ioctl, fd, FBIOGET_FSCREENINFO, (i32)&fix);
    syscall3(SYS_ioctl, fd, FBIOGET_VSCREENINFO, (i32)&var);

    if (fix.smem_len == 0 || var.xres == 0 || var.yres == 0) {
        for (;;) sleep_ms(1000);
    }

    fb = (unsigned char *)syscall6(SYS_mmap2, 0, (i32)fix.smem_len, PROT_RW,
                                   MAP_SHARED, fd, 0);
    if ((i32)fb < 0) {
        for (;;) sleep_ms(1000);
    }

    /* color cycle: each pass repaints the whole screen, so a frozen picture
     * can never be mistaken for a working one */
    for (;;) {
        u32 bg = pack_color(var.bits_per_pixel, 0x000080, &var, 1);
        u32 fg = pack_color(var.bits_per_pixel, 0xFFFFFF, &var, 1);
        fill(fb, &fix, &var, bg);
        {
            int scale = (int)(var.yres / 24);
            int len, w, x, y;
            if (scale < 2) scale = 2;
            len = slen("LINUX");
            w = (len * 6 - 1) * scale;
            x = ((int)var.xres - w) / 2;
            if (x < 0) x = 0;
            y = (int)var.yres / 2 - 4 * scale;
            draw_text(fb, &fix, &var, "LINUX", x, y, scale, fg);
            len = slen("PROBE OK");
            w = (len * 6 - 1) * scale / 2;
            x = ((int)var.xres - w) / 2;
            if (x < 0) x = 0;
            y = (int)var.yres / 2 + 4 * scale;
            draw_text(fb, &fix, &var, "PROBE OK", x, y, scale / 2 > 0 ? scale / 2 : 1, fg);
        }
        sleep_ms(1500);
        fill(fb, &fix, &var, pack_color(var.bits_per_pixel, 0x800000, &var, 1));
        sleep_ms(600);
        fill(fb, &fix, &var, pack_color(var.bits_per_pixel, 0x008000, &var, 1));
        sleep_ms(600);
        fill(fb, &fix, &var, pack_color(var.bits_per_pixel, 0x000080, &var, 1));
        sleep_ms(600);
    }
}
