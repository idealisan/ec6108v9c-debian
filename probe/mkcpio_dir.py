#!/usr/bin/env python3
"""Pack a directory tree into a newc cpio (initramfs) and gzip it."""
import gzip
import os
import stat
import struct
import sys


def hdr(name, mode, size, ino):
    namez = name.encode() + b"\x00"
    return struct.pack("<6s8s8s8s8s8s8s8s8s8s8s8s8s",
                       b"070701", b"%08X" % ino, b"%08X" % mode, b"00000000",
                       b"00000000", b"00000001", b"%08X" % 0,
                       b"%08X" % size, b"00000000", b"00000000",
                       b"00000000", b"00000000", b"%08X" % len(namez)) + namez


def pad4(b):
    return b + b"\x00" * ((4 - len(b) % 4) % 4)


def main():
    root, out = sys.argv[1], sys.argv[2]
    entries = []
    for dirpath, dirnames, filenames in os.walk(root):
        dirnames.sort()
        rel = os.path.relpath(dirpath, root)
        if rel != ".":
            entries.append((rel, "dir", None))
        for fn in sorted(filenames):
            entries.append((os.path.relpath(os.path.join(dirpath, fn), root), "file",
                            os.path.join(dirpath, fn)))
    entries.sort(key=lambda e: e[0])

    blob = b""
    ino = 1
    for name, kind, path in entries:
        ino += 1
        if kind == "dir":
            blob += pad4(hdr(name, 0o040755, 0, ino))
        else:
            data = open(path, "rb").read()
            mode = 0o100755 if os.access(path, os.X_OK) else 0o100644
            blob += pad4(hdr(name, mode, len(data), ino)) + pad4(data)
    blob += pad4(hdr("TRAILER!!!", 0, 0, 0))

    with gzip.open(out, "wb", 9) as fh:
        fh.write(blob)
    print("packed %d entries, cpio=%d, gz=%d bytes" % (len(entries), len(blob), os.path.getsize(out)))


if __name__ == "__main__":
    main()
