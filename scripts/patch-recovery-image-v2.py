#!/usr/bin/env python3
"""Replace the ramdisk of the boot.img at offset 0 of p3, byte-preserving.

The EC6108V9C keeps TWO recoveries in p3 (hiboot has "first-recovery" and
"second-recovery" paths):

    0x000000  current/first recovery boot.img   <- the one hiboot boots
    0x800000  older/second recovery boot.img    <- kept untouched here

Only the ramdisk inside the first boot.img is replaced. Everything after the
new boot.img (including the second copy at 8 MiB) is copied through verbatim,
so the image stays exactly 16 MiB.

Usage: patch-recovery-image-v2.py P3.img RAMDISK.gz OUT.img
"""
import struct
import sys

PAGE = 2048


def pad(b):
    rem = len(b) % PAGE
    return b if rem == 0 else b + bytes([0]) * (PAGE - rem)


def main():
    src, ramdisk, dst = sys.argv[1], sys.argv[2], sys.argv[3]
    d = open(src, "rb").read()
    assert d[:8] == b"ANDROID!", "no boot.img at offset 0"
    ksize, kaddr, rsize, raddr, ssize, saddr, taddr, page = struct.unpack_from("<8I", d, 8)
    assert page == PAGE, "unexpected page size"
    kernel = d[PAGE:PAGE + ksize]
    rd = open(ramdisk, "rb").read()

    hdr = bytearray(d[:PAGE])
    struct.pack_into("<I", hdr, 8, len(kernel))
    struct.pack_into("<I", hdr, 16, len(rd))
    new_boot = pad(bytes(hdr)) + pad(kernel) + pad(rd)
    assert len(new_boot) <= 0x400000, "boot.img would spill past 4 MiB"

    out = new_boot + d[len(new_boot):]
    assert len(out) == len(d), "size changed"
    open(dst, "wb").write(out)
    print("p3: kernel %d (unchanged), ramdisk %d -> %d, boot.img %d bytes, total %d"
          % (ksize, rsize, len(rd), len(new_boot), len(out)))
    print("    bytes after 0x%x preserved verbatim" % len(new_boot))


if __name__ == "__main__":
    main()
