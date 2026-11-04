#!/usr/bin/env python3
"""Replace /res/keys in a recovery ramdisk, leaving every other entry intact.

Usage: swap-recovery-keys.py RAMDISK.gz KEYS.txt OUT.gz

The recovery binary, UI, fstab, init.rc and default.prop are copied through
byte for byte: only the 1.4 KB key file changes, so the recovery still boots
exactly like the stock one - it just trusts our OTA signature instead.
"""
import gzip
import sys


def parse(raw):
    out, i = [], 0
    while True:
        if raw[i:i + 6] != b"070701":
            raise SystemExit("bad cpio magic at %d" % i)
        fields = [int(raw[i + 6 + k * 8:i + 14 + k * 8], 16) for k in range(13)]
        namesz, size = fields[11], fields[6]
        name = raw[i + 110:i + 110 + namesz - 1].decode()
        off = i + 110 + namesz
        off += (4 - off % 4) % 4
        data = raw[off:off + size]
        i = off + size
        i += (4 - i % 4) % 4
        if name == "TRAILER!!!":
            break
        out.append((fields, name, data))
    return out


def emit(entries):
    blob = b""
    for fields, name, data in entries:
        namez = name.encode() + bytes([0])
        fields = list(fields)
        fields[6] = len(data)
        fields[11] = len(namez)
        hdr = b"070701" + b"".join(b"%08X" % f for f in fields)
        blob += hdr + namez
        blob += bytes([0]) * ((4 - len(blob) % 4) % 4)
        blob += data
        blob += bytes([0]) * ((4 - len(data) % 4) % 4)
    trailer = [0] * 13
    namez = b"TRAILER!!!" + bytes([0])
    trailer[11] = len(namez)
    blob += b"070701" + b"".join(b"%08X" % f for f in trailer) + namez
    blob += bytes([0]) * ((4 - len(blob) % 4) % 4)
    return blob


def main():
    src, keys, dst = sys.argv[1], sys.argv[2], sys.argv[3]
    raw = gzip.open(src, "rb").read()
    entries = parse(raw)
    new = open(keys, "rb").read()
    found = False
    for idx, (fields, name, data) in enumerate(entries):
        if name == "res/keys":
            entries[idx] = (fields, name, new)
            found = True
    if not found:
        raise SystemExit("no res/keys entry in ramdisk")
    blob = emit(entries)
    with gzip.open(dst, "wb", 9) as fh:
        fh.write(blob)
    print("replaced res/keys: %d -> %d bytes, %d entries"
          % (len(next(d for f, n, d in entries if n == "res/keys")), len(new), len(entries)))


if __name__ == "__main__":
    main()
