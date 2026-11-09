#!/usr/bin/env python3
"""repack.py -- patch the STOCK EC6108V9C recovery image, USERLAND ONLY.

We keep the stock 3.10 kernel blob byte-for-byte (it owns the hifb/VO/HDMI
drivers that light the panel) and replace exactly ONE file inside the ramdisk:
    sbin/recovery  ->  our compiled `flasher` ELF
Everything else (kernel, header magic, cmdline, all PNG resources) is preserved.

Inputs (repo-relative, all gitignored TMP/):
  TMP/stock-rom-research/extracted/p03_recovery.img   (16 MiB stock partition)
  TMP/recovery-flash-out/flasher                      (our ARM Linux static ELF)

Outputs (TMP/recovery-flash-out/):
  ramdisk-patched.cpio        patched cpio (newc), for inspection
  ramdisk-patched.cpio.gz     gzipped ramdisk
  recovery-kernel.uimage      the UNTOUCHED stock kernel uImage blob
  recovery-ramdisk.uramdisk   ramdisk.gz wrapped in a legacy uImage header
  recovery-flash-boot.img     patched ANDROID! boot.img (header ramdisk_size fixed)

REA notes:
  - boot.img header is at p03 offset 0x800000 (verified by ANDROID! magic scan),
    NOT at 0. The first 8 MiB is a vendor index/prefill area.
  - Android boot.img v0 header (little-endian u32 from offset 8):
      kernel_size, kernel_addr, ramdisk_size, ramdisk_addr,
      second_size, second_addr, tags_addr, page_size
  - kernel blob begins at page_size (0x800) after header and IS a legacy
    uImage (magic 0x27051956, "Linux-3.10.0_s40"); we keep it verbatim.
  - ramdisk is newc cpio + gzip.
  - The 8-word `id` (SHA1) at header+0x240 is left as-is; most vendor
    bootloaders do not verify it. Flagged [unknown] in docs/050.
"""
import gzip
import hashlib
import struct
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
EXTRACTED = ROOT / "TMP/stock-rom-research/extracted"
OUT = ROOT / "TMP/recovery-flash-out"
# The STOCK recovery boot.img is committed in-repo (user decision: no kernel
# source is available, so the binary is a required build input). Prefer it;
# fall back to the full 16 MiB partition dump if present (header lives at
# 0x800000 there, found by magic scan).
STOCK = ROOT / "recovery-flasher/stock/recovery-stock.img"
P03 = EXTRACTED / "p03_recovery.img"
FLASHER = OUT / "flasher"

ANDROID_MAGIC = b"ANDROID!"
UIMAGE_MAGIC = 0x27051956
NEW_CPIO = b"070701"


def find_bootimg(d: bytes) -> int:
    off = d.find(ANDROID_MAGIC)
    if off < 0:
        raise SystemExit("ANDROID! boot.img header not found in p03")
    return off


def parse_cpio(raw: bytes):
    """Yield (fields list[13 int], name bytes incl NUL, data bytes) in order."""
    i = 0
    n = len(raw)
    entries = []
    while i + 110 <= n and raw[i:i+6] == NEW_CPIO:
        hdr = raw[i:i+110].decode("ascii", "replace")
        fields = [int(hdr[6 + 8*k:6 + 8*k + 8], 16) for k in range(13)]
        namesize = fields[11]
        name = raw[i+110:i+110+namesize]
        data_start = (i + 110 + namesize + 3) & ~3
        fsz = fields[6]
        data = raw[data_start:data_start+fsz]
        entries.append((fields, name, data))
        i = (data_start + fsz + 3) & ~3
        if name.rstrip(b"\x00") == b"TRAILER!!!":
            break
    if not entries:
        raise SystemExit("no cpio entries parsed")
    return entries, i


def build_cpio(entries) -> bytes:
    out = bytearray()
    for fields, name, data in entries:
        # refresh filesize (field 6) and namesize (field 11) to be safe
        fields = list(fields)
        fields[6] = len(data)
        fields[11] = len(name)
        fields[12] = 0  # newc 'check' field is always 0
        h = NEW_CPIO + b"".join(b"%08X" % (v & 0xffffffff) for v in fields)
        assert len(h) == 110, len(h)
        out += h
        out += name
        out += b"\x00" * ((-(110 + len(name))) & 3)
        out += data
        out += b"\x00" * ((-len(data)) & 3)
    return bytes(out)


def uimage_header(data: bytes, load: int, ep: int, os_: int, arch: int,
                  typ: int, comp: int, name: bytes) -> bytes:
    """Legacy U-Boot uImage 64-byte header (big-endian)."""
    h = bytearray(64)
    import zlib
    struct.pack_into(">7I", h, 0, UIMAGE_MAGIC, 0, 0,
                     len(data), load, ep, zlib.crc32(data) & 0xffffffff)
    h[28] = os_ & 0xff
    h[29] = arch & 0xff
    h[30] = typ & 0xff
    h[31] = comp & 0xff
    nm = name[:31] + b"\x00"
    h[32:32+len(nm)] = nm
    # header CRC over header with hcrc zeroed
    import zlib
    struct.pack_into(">I", h, 4, 0)
    hcrc = zlib.crc32(bytes(h)) & 0xffffffff
    struct.pack_into(">I", h, 4, hcrc)
    return bytes(h)


def main():
    if not FLASHER.exists():
        raise SystemExit(f"missing {FLASHER} (run build.sh to compile it)")
    if STOCK.exists():
        src = STOCK
    elif P03.exists():
        src = P03
    else:
        raise SystemExit(f"missing both {STOCK} and {P03}")
    OUT.mkdir(parents=True, exist_ok=True)
    d = src.read_bytes()
    base = find_bootimg(d)
    print(f"[observe] source = {src.relative_to(ROOT)}")
    print(f"[observe] boot.img header @ +0x{base:x}")

    hdr = bytearray(d[base:base+0x800])   # full page_size header
    ks, ka, rs, ra, ss, sa, ta, ps = struct.unpack_from("<8I", hdr, 8)
    print(f"[observe] kernel_size={ks} kernel_addr=0x{ka:x} "
          f"ramdisk_size={rs} ramdisk_addr=0x{ra:x} "
          f"second_size={ss} tags=0x{ta:x} page_size={ps}")
    cmdline = hdr[0x40:0x240].split(b"\x00")[0].decode("utf-8", "replace")
    print(f"[observe] cmdline: {cmdline[:120]}")

    kernel_off = base + ps
    kernel = d[kernel_off:kernel_off + ks]
    assert kernel[:4] == struct.pack(">I", UIMAGE_MAGIC), "kernel blob is not a uImage"
    kernel_name = kernel[32:64].split(b"\x00")[0].decode("ascii", "replace")
    print(f"[observe] kernel uImage: {len(kernel)} B, magic OK, name={kernel_name}")

    ramdisk_off = kernel_off + ((ks + ps - 1) // ps) * ps
    ramdisk_gz = d[ramdisk_off:ramdisk_off + rs]
    assert ramdisk_gz[:3] == b"\x1f\x8b\x08", "ramdisk not gzip at expected offset"
    cpio = gzip.decompress(ramdisk_gz)
    print(f"[observe] ramdisk @0x{ramdisk_off - base:x} (boot.img rel): "
          f"{rs} B gzip -> {len(cpio)} B cpio")

    # ---- cpio surgery: replace sbin/recovery ----
    entries, consumed = parse_cpio(cpio)
    print(f"[observe] cpio entries={len(entries)}, parsed {consumed}/{len(cpio)} B")
    flasher = FLASHER.read_bytes()
    replaced = 0
    new_entries = []
    for fields, name, data in entries:
        nm = name.rstrip(b"\x00")
        if nm == b"sbin/recovery":
            print(f"[change] sbin/recovery: {len(data)} B -> {len(flasher)} B "
                  f"(mode={fields[1]:06o} uid={fields[2]} gid={fields[3]})")
            data = flasher
            replaced += 1
        new_entries.append((fields, name, data))
    if replaced != 1:
        raise SystemExit(f"expected exactly 1 sbin/recovery entry, got {replaced}")

    new_cpio = build_cpio(new_entries)
    new_gz = gzip.compress(new_cpio, compresslevel=9, mtime=0)
    (OUT / "ramdisk-patched.cpio").write_bytes(new_cpio)
    (OUT / "ramdisk-patched.cpio.gz").write_bytes(new_gz)
    print(f"[observe] patched cpio {len(new_cpio)} B -> gz {len(new_gz)} B")

    # ---- VERIFY image: byte-for-byte stock kernel+ramdisk, only re-sliced ----
    # Teammate Q5: first flash MUST boot an UNMODIFIED recovery to prove the
    # stock 3.10 kernel lights HDMI in the shorted (flash) branch. Pure slice.
    verify_img = d[base:ramdisk_off + rs]
    (OUT / "recovery-verify.img").write_bytes(verify_img)
    print(f"[product] recovery-verify.img {len(verify_img)} B "
          f"(UNMODIFIED stock, for the go/no-go HDMI check)")

    # ---- patch boot.img header: ramdisk_size ----
    struct.pack_into("<I", hdr, 16, len(new_gz))
    # rebuild boot.img: header(page) + kernel(padded) + new ramdisk
    bootimg = bytearray()
    bootimg += hdr                              # 0x800 header
    bootimg += kernel
    bootimg += b"\x00" * ((-len(bootimg)) & (ps - 1))   # align to page
    bootimg += new_gz
    (OUT / "recovery-flash-boot.img").write_bytes(bootimg)
    print(f"[product] recovery-flash-boot.img {len(bootimg)} B "
          f"(kernel UNTOUCHED, ramdisk_size -> {len(new_gz)})")

    # ---- split artifacts for `bootm <kernel> <ramdisk>` (bypasses Android id) ----
    (OUT / "recovery-kernel.uimage").write_bytes(kernel)
    urd = uimage_header(new_gz, 0, 0, os_=5, arch=2, typ=3, comp=1,
                        name=b"recovery-flash ramdisk")
    (OUT / "recovery-ramdisk.uramdisk").write_bytes(urd + new_gz)
    print(f"[product] recovery-kernel.uimage {len(kernel)} B, "
          f"recovery-ramdisk.uramdisk {len(urd)+len(new_gz)} B")

    # manifest: sha256 of everything
    lines = []
    for p in sorted(OUT.glob("*")):
        if p.is_file() and p.suffix != ".sha256":
            lines.append(f"{hashlib.sha256(p.read_bytes()).hexdigest()}  {p.name}")
    (OUT / "SHA256SUMS.txt").write_text("\n".join(lines) + "\n")
    print("[done]")


if __name__ == "__main__":
    main()
