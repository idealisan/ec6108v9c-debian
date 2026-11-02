#!/usr/bin/env python3
"""Convert a raw ext4 image into an Android sparse image (v1).

Only RAW (0xCAC1) and DONT_CARE (0xCAC3) chunks are emitted - the same two
types found in the stock ECOO images, i.e. the subset that hiboot's
"mmc write.ext4sp" command is known to understand.

Layout: 28-byte file header, 12-byte chunk headers, 4096-byte blocks.

Usage: img2simg.py INPUT.ext4 OUTPUT.sparse.ext4
"""
import argparse
import struct

SPARSE_MAGIC = 0xED26FF3A
CHUNK_RAW = 0xCAC1
CHUNK_DONT_CARE = 0xCAC3
BLOCK = 4096
MAX_RAW_BLOCKS = 4096  # 16 MiB payload per RAW chunk
ZERO_BLOCK = b"\x00" * BLOCK


def scan(path):
    """Pass 1: merge consecutive blocks into RAW / DONT_CARE chunks."""
    chunks = []
    with open(path, "rb") as fh:
        while True:
            block = fh.read(BLOCK)
            if not block:
                break
            if len(block) < BLOCK:
                block = block.ljust(BLOCK, b"\x00")
            ctype = CHUNK_DONT_CARE if block == ZERO_BLOCK else CHUNK_RAW
            if chunks and chunks[-1][0] == ctype:
                if ctype == CHUNK_RAW and chunks[-1][1] >= MAX_RAW_BLOCKS:
                    chunks.append([ctype, 1])
                else:
                    chunks[-1][1] += 1
            else:
                chunks.append([ctype, 1])
    return chunks


def write_sparse(path, chunks, out_path):
    total_blocks = sum(count for _, count in chunks)
    with open(path, "rb") as src, open(out_path, "wb") as out:
        out.write(struct.pack(
            "<IHHHHIIII", SPARSE_MAGIC, 1, 0, 28, 12, BLOCK,
            total_blocks, len(chunks), 0,
        ))
        payload = 0
        for ctype, count in chunks:
            if ctype == CHUNK_RAW:
                size = count * BLOCK
                out.write(struct.pack("<HHII", ctype, 0, count, 12 + size))
                remaining = size
                while remaining:
                    data = src.read(min(remaining, 1 << 20))
                    if not data:
                        raise SystemExit("unexpected end of input")
                    out.write(data)
                    remaining -= len(data)
                payload += size
            else:
                out.write(struct.pack("<HHII", ctype, 0, count, 12))
                src.seek(count * BLOCK, 1)
    return total_blocks, payload


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("input")
    ap.add_argument("output")
    args = ap.parse_args()

    chunks = scan(args.input)
    total_blocks, payload = write_sparse(args.input, chunks, args.output)
    print("wrote %s: %d blocks (%d MiB), %d chunks, %d MiB payload"
          % (args.output, total_blocks, total_blocks * BLOCK >> 20,
             len(chunks), payload >> 20))


if __name__ == "__main__":
    main()
