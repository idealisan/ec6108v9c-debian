#!/usr/bin/env python3
"""Locally patch the p2 runtime-env bootargs.bin so the booted kernel gets a
larger CMA pool.

Why this exists
---------------
The kernel command line that ACTUALLY boots the box is the ``bootargs=`` entry
in the p2 runtime env (``mv100/bootargs.bin`` on the U-disk), written by
``make-community-flash-package.sh`` from ``KERNEL_CMDLINE_NO_MEM``. The DTB
``/chosen/bootargs`` is NOT authoritative on this hiboot. Passing
``extra_cmdline=cma=160M`` to the CI only lands in the DTB (build-kernel job);
the packaging job historically did not forward it into the p2 env, so CMA
stayed at the 16 MiB default.

CMA must be ~160 MiB (per gthifb's histb-mainline board DTS ``media_cma``)
for kmsro/DRI3/PRIME to allocate scanout buffers. With only 16 MiB, Xorg
falls back to zink (no Vulkan ICD present) and the SoC hard-lockups.

This script edits the binary CRC32 env in place-format: it appends
``cma=<SIZE>`` to the ``bootargs`` value, keeps every other key/value pair and
order intact, and recomputes the leading CRC32 so hiboot accepts it.

Usage
-----
    python3 scripts/fix-cma-bootargs.py INPUT.bin OUTPUT.bin [--size 160M] \
        [--add-key] [--force]

It is idempotent: if ``bootargs`` already contains ``cma=`` it is left as-is
(unless --force, which replaces an existing ``cma=<...>`` token).
"""
import argparse
import struct
import zlib

ENV_SIZE = 65536
BODY_SIZE = ENV_SIZE - 4


def read_pairs(data: bytes):
    assert len(data) == ENV_SIZE, f"bad env size {len(data)}"
    hdr_crc = struct.unpack_from("<I", data, 0)[0]
    body = data[4:]
    calc_crc = zlib.crc32(body) & 0xFFFFFFFF
    assert hdr_crc == calc_crc, (
        f"input CRC mismatch: header 0x{hdr_crc:08x} != calc 0x{calc_crc:08x}")
    pairs = []
    for kv in body.split(b"\x00"):
        if not kv:
            continue
        assert b"=" in kv, f"bad env entry {kv!r}"
        k, v = kv.split(b"=", 1)
        pairs.append((k, v))
    return pairs


def build(pairs) -> bytes:
    body = bytearray()
    for k, v in pairs:
        body += k + b"=" + v + b"\x00"
    assert len(body) <= BODY_SIZE, f"env too large: {len(body)} > {BODY_SIZE}"
    body = body.ljust(BODY_SIZE, b"\x00")
    crc = zlib.crc32(body) & 0xFFFFFFFF
    return struct.pack("<I", crc) + bytes(body)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("input")
    ap.add_argument("output")
    ap.add_argument("--size", default="160M",
                    help="CMA pool size (default 160M)")
    ap.add_argument("--force", action="store_true",
                    help="replace an existing cma=<...> token instead of no-op")
    args = ap.parse_args()

    data = open(args.input, "rb").read()
    pairs = read_pairs(data)

    token = b"cma=" + args.size.encode()
    found = 0
    for n, (k, v) in enumerate(pairs):
        if k != b"bootargs":
            continue
        found += 1
        if b"cma=" in v:
            if not args.force:
                print("bootargs already has cma=; leaving unchanged (use --force to replace)")
                out = data
                break
            # strip an existing cma=<token> word
            words = [w for w in v.split(b" ") if not w.startswith(b"cma=")]
            v = b" ".join(words)
        new_v = v + b" " + token
        pairs[n] = (k, new_v)
        print("new bootargs:", new_v.decode("ascii", "replace"))
        out = build(pairs)
        break
    else:
        raise SystemExit("no bootargs= entry found in env")
    assert found == 1

    open(args.output, "wb").write(out)
    # verify the file we wrote
    check = open(args.output, "rb").read()
    assert len(check) == ENV_SIZE
    assert struct.unpack_from("<I", check, 0)[0] == (zlib.crc32(check[4:]) & 0xFFFFFFFF)
    assert token in check[4:]
    print(f"wrote {args.output}: {len(pairs)} vars, {len(check)} bytes, CRC ok, {token.decode()} present")


if __name__ == "__main__":
    main()
