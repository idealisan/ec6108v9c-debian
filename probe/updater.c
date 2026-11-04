/* update-binary for the recovery test / flash package.
 *
 * KK recovery unpacks META-INF/com/google/android/update-binary into /tmp and
 * execs it (argv: version, pipe fd, zip path). It is a plain ARM ELF, so if the
 * signature check lets the package through, this code runs with root and can
 * touch the eMMC.
 *
 * Mode is chosen by a marker file on the USB stick:
 *   /usb/PROBE.txt        -> only write markers back and exit (safe test)
 *   /usb/FLASH.txt        -> dd /usb/rescue-boot.img into the kernel partition
 * Anything else: write markers only.
 */
typedef int i32;
typedef unsigned int u32;

#define SYS_exit   1
#define SYS_read   3
#define SYS_write  4
#define SYS_open   5
#define SYS_close  6
#define SYS_lseek  19
#define SYS_mount  21
#define SYS_mkdir  39
#define SYS_sync   36
#define SYS_reboot 88
#define SYS_nanosleep 162

#define O_RDONLY 0
#define O_WRONLY 1
#define O_CREAT  0100
#define O_TRUNC  01000

static inline i32 sys3(i32 n, i32 a, i32 b, i32 c)
{
    register i32 r7 __asm__("r7") = n;
    register i32 r0 __asm__("r0") = a;
    register i32 r1 __asm__("r1") = b;
    register i32 r2 __asm__("r2") = c;
    __asm__ volatile("svc #0" : "+r"(r0) : "r"(r7), "r"(r1), "r"(r2) : "memory");
    return r0;
}

static inline i32 sys5(i32 n, i32 a, i32 b, i32 c, i32 d, i32 e)
{
    register i32 r7 __asm__("r7") = n;
    register i32 r0 __asm__("r0") = a;
    register i32 r1 __asm__("r1") = b;
    register i32 r2 __asm__("r2") = c;
    register i32 r3 __asm__("r3") = d;
    register i32 r4 __asm__("r4") = e;
    __asm__ volatile("svc #0" : "+r"(r0) : "r"(r7), "r"(r1), "r"(r2), "r"(r3), "r"(r4) : "memory");
    return r0;
}

static int slen(const char *s) { int n = 0; while (s[n]) n++; return n; }

static void note(const char *msg)
{
    int fd;
    fd = sys3(SYS_open, (i32)"/usb/UPDATER_RAN.txt", O_WRONLY | O_CREAT | O_TRUNC, 0644);
    if (fd < 0)
        fd = sys3(SYS_open, (i32)"/tmp/UPDATER_RAN.txt", O_WRONLY | O_CREAT | O_TRUNC, 0644);
    if (fd >= 0) {
        sys3(SYS_write, fd, (i32)msg, slen(msg));
        sys3(SYS_close, fd, 0, 0);
    }
    fd = sys3(SYS_open, (i32)"/sdcard/UPDATER_RAN.txt", O_WRONLY | O_CREAT | O_TRUNC, 0644);
    if (fd >= 0) {
        sys3(SYS_write, fd, (i32)msg, slen(msg));
        sys3(SYS_close, fd, 0, 0);
    }
}

static int exists(const char *p)
{
    int fd = sys3(SYS_open, (i32)p, O_RDONLY, 0);
    if (fd >= 0) { sys3(SYS_close, fd, 0, 0); return 1; }
    return 0;
}

/* copy src -> dst, returns bytes written or negative */
static i32 copy_file(const char *src, const char *dst)
{
    static char buf[65536];
    i32 in, out, n, total = 0;
    in = sys3(SYS_open, (i32)src, O_RDONLY, 0);
    if (in < 0) return -1;
    out = sys3(SYS_open, (i32)dst, O_WRONLY | O_CREAT | O_TRUNC, 0644);
    if (out < 0) { sys3(SYS_close, in, 0, 0); return -2; }
    while ((n = sys3(SYS_read, in, (i32)buf, sizeof(buf))) > 0) {
        i32 off = 0;
        while (off < n) {
            i32 w = sys3(SYS_write, out, (i32)(buf + off), n - off);
            if (w <= 0) break;
            off += w;
        }
        total += n;
    }
    sys3(SYS_close, in, 0, 0);
    sys3(SYS_close, out, 0, 0);
    sys3(SYS_sync, 0, 0, 0);
    return total;
}

void _start(void)
{
    if (exists("/usb/ROLLBACK.txt")) {
        i32 r = copy_file("/usb/p11_stock.img", "/dev/block/platform/hi_mci.1/by-name/kernel");
        note(r == 12582912 ? "rollback: stock p11 restored\n" : "rollback: failed\n");
        sys3(SYS_reboot, 0xfee1dead, 672274793, 0x01234567);
    }
    if (exists("/usb/FLASH.txt")) {
        i32 b = copy_file("/dev/block/platform/hi_mci.1/by-name/kernel", "/usb/p11_stock.img");
        if (b != 12582912) {
            note("flash: backup of kernel partition failed or short, aborting\n");
            sys3(SYS_exit, 1, 0, 0);
        }
        {
            i32 r = copy_file("/usb/rescue-boot.img", "/dev/block/platform/hi_mci.1/by-name/kernel");
            note(r > 0 ? "flash: rescue-boot.img written to kernel partition\n"
                       : "flash: write failed\n");
        }
        sys3(SYS_reboot, 0xfee1dead, 672274793, 0x01234567);
    }
    note("UPDATER RAN: recovery executed an unsigned update-binary\n");
    sys3(SYS_exit, 0, 0, 0);
}
