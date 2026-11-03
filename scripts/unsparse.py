#!/usr/bin/env python3
"""Convert an Android sparse image back into a raw image.

Mirror of scripts/img2simg.py, used by scripts/inspect-rom.sh when a package
contains sparse system images.
"""
import argparse
import struct

SPARSE_MAGIC = 0xED26FF3A
CHUNK_RAW = 0xCAC1
CHUNK_FILL = 0xCAC2
CHUNK_DONT_CARE = 0xCAC3
CHUNK_CRC32 = 0xCAC4


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("input")
    ap.add_argument("output")
    args = ap.parse_args()

    with open(args.input, "rb") as src, open(args.output, "wb") as out:
        header = src.read(28)
        magic, major, minor, fhs, chs, blk, total_blocks, total_chunks, _ = \
            struct.unpack("<IHHHHIIII", header)
        if magic != SPARSE_MAGIC:
            raise SystemExit("not a sparse image")
        for _ in range(total_chunks):
            ctype, _, blocks, total_sz = struct.unpack("<HHII", src.read(12))
            payload = total_sz - 12
            if ctype == CHUNK_RAW:
                out.write(src.read(payload))
            elif ctype == CHUNK_FILL:
                pattern = src.read(4)
                out.write(pattern * (blocks * blk // 4))
            elif ctype == CHUNK_DONT_CARE:
                out.seek(blocks * blk, 1)
            elif ctype == CHUNK_CRC32:
                src.read(payload)
            else:
                raise SystemExit("unknown chunk type 0x%04x" % ctype)
        out.truncate(total_blocks * blk)


if __name__ == "__main__":
    main()
