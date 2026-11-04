#!/usr/bin/env python3
"""Pack one file into a newc cpio archive (initramfs), then gzip it."""
import os
import struct
import sys


def entry(name, data, mode=0o100755, ino=1):
    namez = name.encode() + b"\x00"
    hdr = struct.pack("<6s8s8s8s8s8s8s8s8s8s8s8s8s",
                      b"070701", b"%08X" % ino, b"%08X" % mode, b"00000000",
                      b"00000000", b"00000001", b"%08X" % os.getpid(),
                      b"%08X" % len(data), b"00000000", b"00000000",
                      b"00000000", b"00000000", b"%08X" % (len(namez)))
    out = hdr + namez
    out += b"\x00" * ((4 - len(out) % 4) % 4)
    out += data
    out += b"\x00" * ((4 - len(data) % 4) % 4)
    return out


def trailer():
    return struct.pack("<6s8s8s8s8s8s8s8s8s8s8s8s8s",
                       b"070701", b"0"*8, b"0"*8, b"0"*8, b"0"*8, b"0"*8,
                       b"0"*8, b"0"*8, b"0"*8, b"0"*8, b"0"*8, b"0"*8, b"0"*8)


def main():
    src, out = sys.argv[1], sys.argv[2]
    data = open(src, "rb").read()
    blob = entry("init", data)
    blob += entry("dev", b"", mode=0o040755, ino=2)
    blob += trailer()
    import gzip
    with gzip.open(out, "wb", 9) as fh:
        fh.write(blob)
    print("wrote %s: init=%d bytes, cpio=%d, gz=%d"
          % (out, len(data), len(blob), os.path.getsize(out)))


if __name__ == "__main__":
    main()
