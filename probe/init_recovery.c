/* Tiny init for the p3-hosted rescue.
 *
 * The recovery slot only has 8 MiB for the boot.img and the proven kernel
 * (p11's 3.10, which carries the hieth-sf ethernet driver) is already 7.9 MiB,
 * so there is no room for busybox here. Instead this 3 KB binary mounts the
 * Android userdata partition and execs:
 *
 *      /data/rescue/busybox sh /data/rescue/init.sh
 *
 * The tools live in /data, which Android can update at any time, while the
 * rescue itself lives in p3 - independent of p11, so a broken p11 no longer
 * takes the rescue down with it.
 */
typedef int i32;
typedef unsigned int u32;

#define SYS_exit   1
#define SYS_execve 11
#define SYS_mount  21
#define SYS_mkdir  39
#define SYS_nanosleep 162

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

static void write_str(const char *p, const char *s)
{
    i32 fd = sys3(5 /* open */, (i32)p, 1 /* O_WRONLY */, 0);
    if (fd >= 0) {
        sys3(4 /* write */, fd, (i32)s, slen(s));
        sys3(6 /* close */, fd, 0, 0);
    }
}

static void msleep(u32 ms)
{
    struct { u32 s, ns; } ts;
    ts.s = ms / 1000;
    ts.ns = (ms % 1000) * 1000000u;
    sys3(SYS_nanosleep, (i32)&ts, 0, 0);
}

void _start(void)
{
    i32 i;

    sys3(SYS_mkdir, (i32)"/dev", 0755, 0);
    sys5(SYS_mount, (i32)"devtmpfs", (i32)"/dev", (i32)"devtmpfs", 0, 0);
    sys3(SYS_mkdir, (i32)"/proc", 0755, 0);
    sys5(SYS_mount, (i32)"proc", (i32)"/proc", (i32)"proc", 0, 0);
    sys3(SYS_mkdir, (i32)"/data", 0755, 0);

    for (i = 0; i < 40; i++) {
        if (sys5(SYS_mount, (i32)"/dev/mmcblk0p16", (i32)"/data", (i32)"ext4", 0, 0) == 0)
            break;
        msleep(250);
    }

    if (i == 40)
        write_str("/dev/kmsg", "rescue: cannot mount /dev/mmcblk0p16\n");

    {
        char *argv[] = { "/data/rescue/busybox", "sh", "/data/rescue/init.sh", 0 };
        char *envp[] = { "PATH=/data/rescue:/bin:/sbin:/system/bin", "HOME=/",
                         "TERM=linux", "LD_LIBRARY_PATH=/data/rescue", 0 };
        sys3(SYS_execve, (i32)"/data/rescue/busybox", (i32)argv, (i32)envp);
    }
    {
        char *argv[] = { "/system/bin/sh", "-c", "echo rescue: busybox exec failed", 0 };
        char *envp[] = { "PATH=/system/bin:/sbin", 0 };
        sys3(SYS_execve, (i32)"/system/bin/sh", (i32)argv, (i32)envp);
    }
    for (;;) msleep(1000);
}
