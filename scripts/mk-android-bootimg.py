#!/usr/bin/env python3
"""Build an Android boot.img (v0 header) wrapping a Linux zImage + appended DTB.

Parameters mirror the stock EC6108V9C p11 image:
    kernel_addr = 0x03E08000
    ramdisk_addr= 0x04E00000
    tags_addr   = 0x03E00100
    page_size   = 2048
"""
import argparse
import struct

PAGE = 2048


def pad(data, page=PAGE):
    rem = len(data) % page
    return data if rem == 0 else data + b"\x00" * (page - rem)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("kernel", help="zImage (with appended DTB)")
    ap.add_argument("output")
    ap.add_argument("--cmdline", required=True)
    ap.add_argument("--kernel-addr", default="0x03E08000")
    ap.add_argument("--ramdisk", default=None)
    ap.add_argument("--ramdisk-addr", default="0x04E00000")
    ap.add_argument("--tags-addr", default="0x03E00100")
    ap.add_argument("--name", default="linux-hi3798mv100")
    args = ap.parse_args()

    kernel = open(args.kernel, "rb").read()
    ramdisk = open(args.ramdisk, "rb").read() if args.ramdisk else b""
    if len(kernel) > 20 * 1024 * 1024:
        raise SystemExit("kernel too large for the 12 MiB partition")

    cmd = args.cmdline.encode()[:511]
    hdr = bytearray(64 + 512 + 32 + 1024)
    hdr[0:8] = b"ANDROID!"
    struct.pack_into("<I", hdr, 8, len(kernel))
    struct.pack_into("<I", hdr, 12, int(args.kernel_addr, 16))
    struct.pack_into("<I", hdr, 16, len(ramdisk))
    struct.pack_into("<I", hdr, 20, int(args.ramdisk_addr, 16))
    struct.pack_into("<I", hdr, 24, 0)                    # second_size
    struct.pack_into("<I", hdr, 28, 0x04D00000)           # second_addr
    struct.pack_into("<I", hdr, 32, int(args.tags_addr, 16))
    struct.pack_into("<I", hdr, 36, PAGE)
    struct.pack_into("<I", hdr, 40, 0)                    # header_version
    struct.pack_into("<I", hdr, 44, 0)                    # os_version
    hdr[48:48 + 16] = args.name.encode()[:15].ljust(16, b"\x00")
    hdr[64:64 + len(cmd)] = cmd

    out = pad(bytes(hdr)) + pad(kernel) + (pad(ramdisk) if ramdisk else b"")
    open(args.output, "wb").write(out)
    print("wrote %s: kernel=%d ramdisk=%d total=%d (%.1f MiB)"
          % (args.output, len(kernel), len(ramdisk), len(out), len(out) / 1048576))


if __name__ == "__main__":
    main()
