#!/usr/bin/env python3
"""Build a distinct boot logo for our Debian flash package.

The stock community logo.img is a Hisilicon "LOGO_TABLE" container. Its
8 KiB parameter table (MCE_DEF_LOGOPARAM_SIZE) is:

  0x0000  "###\\0" + u32 table length (0x7c)
  0x0008  "LOGO_TABLE"
  0x0028  u32 0x50          (offset/anchor used by the PDM key parser)
  0x002c  "LOGO_KEY_FLAG"   name
  0x004c  u32 4             value length
  0x0050  u32 1             value (logo present)
  0x0054  "LOGO_KEY_LEN"    name
  0x0074  u32 4             value length
  0x0078  u32 <jpeg len>    value
  0x2000  JPEG data (924x529 in the community image)
  rest    zero padding to 64 KiB

We rebuild that container from scratch (no external binary template needed,
so CI can reproduce it), replace the JPEG with our own "Debian Linux" image,
and set LOGO_KEY_LEN to the new JPEG length. hiboot's PDM reads the table by
partition name and HI_LOGO_DecImg decodes the JPEG, so a valid JPEG of the
same dimensions is all that is required.

Usage:
  python3 scripts/make-flash-logo.py OUTPUT-logo.img \
      [--text "Debian Linux"] [--png WORK.png] [--jpeg WORK.jpg] \
      [--compare STOCK-logo.img]

The JPEG is produced with macOS `sips` from a PNG generated here with a
built-in 5x7 bitmap font, so no PIL / ImageMagick is needed.
"""
import argparse
import struct
import subprocess
import zlib

TABLE_LEN = 0x2000          # MCE_DEF_LOGOPARAM_SIZE
IMG_LEN = 0x10000           # logo partition payload size (64 KiB)
LOGO_KEY_LEN_OFF = 0x78
WIDTH, HEIGHT = 924, 529    # same as the stock JPEG

FONT = {
    'A': [0x7E, 0x11, 0x11, 0x11, 0x7E], 'B': [0x7F, 0x49, 0x49, 0x49, 0x36],
    'C': [0x3E, 0x41, 0x41, 0x41, 0x22], 'D': [0x7F, 0x41, 0x41, 0x22, 0x1C],
    'E': [0x7F, 0x49, 0x49, 0x49, 0x41], 'F': [0x7F, 0x09, 0x09, 0x09, 0x01],
    'G': [0x3E, 0x41, 0x49, 0x49, 0x7A], 'H': [0x7F, 0x08, 0x08, 0x08, 0x7F],
    'I': [0x00, 0x41, 0x7F, 0x41, 0x00], 'J': [0x20, 0x40, 0x41, 0x3F, 0x01],
    'K': [0x7F, 0x08, 0x14, 0x22, 0x41], 'L': [0x7F, 0x40, 0x40, 0x40, 0x40],
    'M': [0x7F, 0x02, 0x0C, 0x02, 0x7F], 'N': [0x7F, 0x04, 0x08, 0x10, 0x7F],
    'O': [0x3E, 0x41, 0x41, 0x41, 0x3E], 'P': [0x7F, 0x09, 0x09, 0x09, 0x06],
    'Q': [0x3E, 0x41, 0x51, 0x21, 0x5E], 'R': [0x7F, 0x09, 0x19, 0x29, 0x46],
    'S': [0x46, 0x49, 0x49, 0x49, 0x31], 'T': [0x01, 0x01, 0x7F, 0x01, 0x01],
    'U': [0x3F, 0x40, 0x40, 0x40, 0x3F], 'V': [0x1F, 0x20, 0x40, 0x20, 0x1F],
    'W': [0x3F, 0x40, 0x38, 0x40, 0x3F], 'X': [0x63, 0x14, 0x08, 0x14, 0x63],
    'Y': [0x07, 0x08, 0x70, 0x08, 0x07], 'Z': [0x61, 0x51, 0x49, 0x45, 0x43],
    '0': [0x3E, 0x51, 0x49, 0x45, 0x3E], '1': [0x00, 0x42, 0x7F, 0x40, 0x00],
    '2': [0x42, 0x61, 0x51, 0x49, 0x46], '3': [0x21, 0x41, 0x45, 0x4B, 0x31],
    '4': [0x18, 0x14, 0x12, 0x7F, 0x10], '5': [0x27, 0x45, 0x45, 0x45, 0x39],
    '6': [0x3C, 0x4A, 0x49, 0x49, 0x30], '7': [0x01, 0x71, 0x09, 0x05, 0x03],
    '8': [0x36, 0x49, 0x49, 0x49, 0x36], '9': [0x06, 0x49, 0x49, 0x29, 0x1E],
    '-': [0x08, 0x08, 0x08, 0x08, 0x08], '.': [0x00, 0x60, 0x60, 0x00, 0x00],
    ' ': [0x00, 0x00, 0x00, 0x00, 0x00],
}

BG = (12, 24, 48)
FG = (240, 240, 240)
ACCENT = (90, 180, 255)


def build_table(jpeg_len):
    """Recreate the 8 KiB LOGO_TABLE parameter block byte-for-byte."""
    t = bytearray(TABLE_LEN)
    t[0:4] = b'###\x00'
    struct.pack_into('<I', t, 0x04, 0x7c)
    t[0x08:0x12] = b'LOGO_TABLE'
    struct.pack_into('<I', t, 0x28, 0x50)
    t[0x2c:0x39] = b'LOGO_KEY_FLAG'
    struct.pack_into('<I', t, 0x4c, 4)
    struct.pack_into('<I', t, 0x50, 1)
    t[0x54:0x60] = b'LOGO_KEY_LEN'
    struct.pack_into('<I', t, 0x74, 4)
    struct.pack_into('<I', t, LOGO_KEY_LEN_OFF, jpeg_len)
    return t


def png_to_jpeg(png_path, jpg_path):
    """Prefer Pillow (available on CI via python3-pil), else macOS sips."""
    try:
        from PIL import Image
        Image.open(png_path).convert('RGB').save(jpg_path, 'JPEG', quality=85)
        return 'PIL'
    except ImportError:
        pass
    subprocess.run(['sips', '-s', 'format', 'jpeg',
                    '-s', 'formatOptions', '85', png_path, '--out', jpg_path],
                   check=True, stdout=subprocess.DEVNULL,
                   stderr=subprocess.DEVNULL)
    return 'sips'


def render_png(text, path):
    scale = 9
    gw, gh, gap = 5 * scale, 7 * scale, scale
    chars = [c.upper() for c in text if c.upper() in FONT]
    text_w = len(chars) * (gw + gap) - gap
    x0 = (WIDTH - text_w) // 2
    y0 = (HEIGHT - gh) // 2

    rows = []
    for y in range(HEIGHT):
        row = bytearray()
        for _ in range(WIDTH):
            r, g, b = ACCENT if (HEIGHT // 2 - 60 <= y <= HEIGHT // 2 - 56) else BG
            row += bytes((r, g, b))
        rows.append(row)

    for idx, ch in enumerate(chars):
        cx = x0 + idx * (gw + gap)
        for c in range(5):
            for bit in range(7):
                if FONT[ch][c] & (1 << bit):
                    px, py = cx + c * scale, y0 + bit * scale
                    for yy in range(py, min(py + scale, HEIGHT)):
                        for xx in range(px, min(px + scale, WIDTH)):
                            rows[yy][3 * xx:3 * xx + 3] = bytes(FG)

    raw = b''.join(b'\x00' + bytes(r) for r in rows)

    def chunk(tag, data):
        return (struct.pack('>I', len(data)) + tag + data +
                struct.pack('>I', zlib.crc32(tag + data) & 0xffffffff))

    png = b'\x89PNG\r\n\x1a\n'
    png += chunk(b'IHDR', struct.pack('>IIBBBBB', WIDTH, HEIGHT, 8, 2, 0, 0, 0))
    png += chunk(b'IDAT', zlib.compress(raw, 9))
    png += chunk(b'IEND', b'')
    open(path, 'wb').write(png)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('dst')
    ap.add_argument('--text', default='Debian Linux')
    ap.add_argument('--png', default='build/flash-logo.png')
    ap.add_argument('--jpeg', default='build/flash-logo.jpg')
    ap.add_argument('--compare', default=None,
                    help='optional stock logo.img to verify our table matches')
    args = ap.parse_args()

    render_png(args.text, args.png)
    backend = png_to_jpeg(args.png, args.jpeg)
    jpeg = open(args.jpeg, 'rb').read()

    out = bytearray(build_table(len(jpeg)))
    out += jpeg
    if len(out) < IMG_LEN:
        out += b'\x00' * (IMG_LEN - len(out))
    out = out[:IMG_LEN]
    open(args.dst, 'wb').write(bytes(out))
    print('  logo: %d B, text="%s", jpeg=%d B, LOGO_KEY_LEN=%d, encoder=%s' %
          (len(out), args.text, len(jpeg), len(jpeg), backend))

    if args.compare:
        stock = open(args.compare, 'rb').read()
        # only LOGO_KEY_LEN (0x78) may differ
        diffs = [i for i in range(TABLE_LEN) if stock[i] != out[i]]
        bad = [hex(i) for i in diffs if i not in range(0x78, 0x7c)]
        print('  table vs stock: differing bytes %s -> %s' %
              ([hex(i) for i in diffs] or 'none',
               'OK (only LOGO_KEY_LEN)' if not bad else 'MISMATCH ' + str(bad)))


if __name__ == '__main__':
    main()
