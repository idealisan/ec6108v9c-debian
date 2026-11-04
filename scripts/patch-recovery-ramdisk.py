#!/usr/bin/env python3
"""Add a shell path to the stock Hi3798MV100 recovery ramdisk.

The stock recovery ships ro.debuggable=0 (so adbd never starts) and never
mounts /system (adbd's shell is /system/bin/sh), which is why 'adb shell' in
recovery normally fails. Two tiny edits fix both:

  default.prop : ro.debuggable=1        -> the existing init.rc rule starts adbd
  init.rc      : mount system at /system -> adbd can exec /system/bin/sh

The recovery UI, its binary, keys and fstab stay byte-identical, so this is an
additive change: if the mount fails recovery still boots as before.
"""
import gzip
import sys


def parse(raw):
    out = []
    i = 0
    while True:
        if raw[i:i + 6] != b"070701":
            raise SystemExit("bad cpio magic at %d" % i)
        fields = [int(raw[i + 6 + k * 8:i + 14 + k * 8], 16) for k in range(13)]
        namesz, size = fields[11], fields[6]
        name = raw[i + 110:i + 110 + namesz - 1].decode()
        data_off = i + 110 + namesz
        data_off += (4 - data_off % 4) % 4
        data = raw[data_off:data_off + size]
        i = data_off + size
        i += (4 - i % 4) % 4
        if name == "TRAILER!!!":
            break
        out.append((fields, name, data))
    return out


def emit(entries):
    blob = b""
    for fields, name, data in entries:
        namez = name.encode() + b"\x00"
        fields = list(fields)
        fields[6] = len(data)
        fields[11] = len(namez)
        hdr = b"070701" + b"".join(b"%08X" % f for f in fields)
        blob += hdr + namez
        blob += b"\x00" * ((4 - len(blob) % 4) % 4)
        blob += data
        blob += b"\x00" * ((4 - len(data) % 4) % 4)
    trailer = [0] * 13
    namez = b"TRAILER!!!\x00"
    trailer[6] = 0
    trailer[11] = len(namez)
    blob += b"070701" + b"".join(b"%08X" % f for f in trailer) + namez
    blob += b"\x00" * ((4 - len(blob) % 4) % 4)
    return blob


def main():
    src, dst = sys.argv[1], sys.argv[2]
    raw = gzip.open(src, "rb").read()
    entries = parse(raw)
    changed = []
    for idx, (fields, name, data) in enumerate(entries):
        if name == "default.prop":
            new = data.replace(b"ro.debuggable=0", b"ro.debuggable=1")
            entries[idx] = (fields, name, new)
            changed.append((name, len(data), len(new)))
        elif name == "init.rc":
            new = data.replace(
                b"    mount /tmp /tmp tmpfs\n",
                b"    mount /tmp /tmp tmpfs\n"
                b"    mount ext4 /dev/block/platform/hi_mci.1/by-name/system /system ro\n",
                1)
            entries[idx] = (fields, name, new)
            changed.append((name, len(data), len(new)))
    blob = emit(entries)
    with gzip.open(dst, "wb", 9) as fh:
        fh.write(blob)
    print("patched:", changed)
    print("wrote %s (%d bytes)" % (dst, len(open(dst, 'rb').read())))


if __name__ == "__main__":
    main()
