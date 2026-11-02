#!/usr/bin/env python3
"""Generate a HiSilicon hiboot bootargs.bin file.

Format (verified against three stock ECOO images):

    [4-byte little-endian CRC32 of the remaining 65532 bytes]
    [NUL separated "key=value" entries]
    [zero padding up to 65536 bytes]

The hiboot refuses to run an environment whose header CRC does not match
("bootargs crc failed !"), so this must be recomputed for every edit.

Usage: mkbootargs.py INPUT.env OUTPUT.bin [--size 65536]
"""
import argparse
import struct
import zlib


def read_env(path):
    pairs = []
    with open(path, "r", encoding="utf-8") as fh:
        for lineno, line in enumerate(fh, 1):
            line = line.rstrip("\n")
            if not line or line.lstrip().startswith("#"):
                continue
            if "=" not in line:
                raise SystemExit("bad env line %d: %r" % (lineno, line))
            key, value = line.split("=", 1)
            key = key.strip()
            if not key:
                raise SystemExit("empty key on line %d" % lineno)
            pairs.append((key, value.strip()))
    if not pairs:
        raise SystemExit("empty environment")
    return pairs


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("env_file")
    ap.add_argument("output")
    ap.add_argument("--size", type=int, default=65536)
    args = ap.parse_args()

    pairs = read_env(args.env_file)
    body = b"".join(
        key.encode() + b"=" + value.encode() + b"\x00" for key, value in pairs
    )
    limit = args.size - 4
    if len(body) > limit:
        raise SystemExit("environment too large: %d > %d bytes" % (len(body), limit))
    body = body.ljust(limit, b"\x00")
    crc = zlib.crc32(body) & 0xFFFFFFFF

    with open(args.output, "wb") as fh:
        fh.write(struct.pack("<I", crc))
        fh.write(body)

    print("wrote %s: %d vars, %d bytes, crc32=0x%08x"
          % (args.output, len(pairs), args.size, crc))


if __name__ == "__main__":
    main()
