#!/usr/bin/env python3
"""Rebuild p03 (recovery) with a patched ramdisk, keeping everything else.

The stock p03 layout is:
    0 .. 8 MiB      : HiSilicon recovery descriptor (left untouched)
    8 MiB .. end    : a plain Android boot.img (kernel + recovery ramdisk)

Only the ramdisk inside that boot.img is replaced; the kernel, the header
addresses, the cmdline and the descriptor are copied through byte for byte and
the boot.img is padded back to its original size.
"""
import struct
import sys

BOOT_OFF = 8388608


def main():
    src, ramdisk, dst = sys.argv[1], sys.argv[2], sys.argv[3]
    d = open(src, "rb").read()
    boot = d[BOOT_OFF:]
    assert boot[:8] == b"ANDROID!", "no boot.img at 8 MiB"
    ksize, kaddr, rsize, raddr, ssize, saddr, taddr, page = struct.unpack_from("<8I", boot, 8)
    kernel = boot[page:page + ksize]
    rd = open(ramdisk, "rb").read()

    hdr = bytearray(boot[: page])
    struct.pack_into("<I", hdr, 8, len(kernel))
    struct.pack_into("<I", hdr, 16, len(rd))
    hdr[64:64 + 512] = boot[64:64 + 512]

    def pad(b, p=page):
        rem = len(b) % p
        return b if rem == 0 else b + b"\x00" * (p - rem)

    new_boot = pad(bytes(hdr)) + pad(kernel) + pad(rd)
    if len(new_boot) > len(boot):
        raise SystemExit("new boot.img (%d) does not fit the %d byte region" % (len(new_boot), len(boot)))
    new_boot += b"\x00" * (len(boot) - len(new_boot))

    open(dst, "wb").write(d[:BOOT_OFF] + new_boot)
    print("kernel %d (unchanged), ramdisk %d -> %d, image %d bytes"
          % (ksize, rsize, len(rd), BOOT_OFF + len(new_boot)))


if __name__ == "__main__":
    main()
