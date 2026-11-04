#!/usr/bin/env python3
"""Sign/verify OTA zips the way KK recovery's verify_file() expects.

This recovery (Android 4.4.2, Huawei Hi3798MV100) uses the classic
bootable/recovery verifier:

  * /res/keys is mincrypt's dumpkey v1 format:
        {64,0x<n0inv>,{64 LE words of n},{64 LE words of R^2 mod n}}
    v1 keys imply public exponent 3, so the key MUST be generated with e=3.
  * the whole-file signature is an RSA-2048 PKCS#1 v1.5 signature over SHA-1
    of everything up to (but excluding) the 2-byte EOCD comment length field;
  * the signature (256 bytes) is stored at the end of the ZIP comment,
    followed by the 6-byte footer
        [uint16 signature_start=262][0xff][0xff][uint16 comment_size=262]

Subcommands:
    keygen OUT.pem
    keys    PEM OUT.txt
    sign    UNSIGNED.zip PEM OUT.zip [--hash sha1|sha256]
    verify  SIGNED.zip KEYS.txt [--hash sha1|sha256]
"""
import argparse
import hashlib
import os
import re
import struct
import subprocess
import sys
import tempfile

RSANUMBYTES = 256
FOOTER_SIZE = 6
EOCD_HEADER_SIZE = 22
COMMENT_SIZE = RSANUMBYTES + FOOTER_SIZE  # 262
EOCD_MAGIC = b"PK" + bytes([0x05, 0x06])

DIGEST_INFO = {
    "sha1": bytes.fromhex("3021300906052b0e03021a05000414"),
    "sha256": bytes.fromhex("3031300d060960864801650304020105000420"),
}


def cmd_keygen(out):
    subprocess.check_call([
        "openssl", "genpkey", "-algorithm", "RSA",
        "-pkeyopt", "rsa_keygen_bits:2048",
        "-pkeyopt", "rsa_keygen_pubexp:3", "-out", out,
    ], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    print("generated RSA-2048 e=3:", out)


def read_modulus(pem):
    txt = subprocess.check_output(
        ["openssl", "rsa", "-in", pem, "-noout", "-modulus"], text=True)
    n = int(txt.strip().split("=", 1)[1], 16)
    if n.bit_length() != 2048:
        raise SystemExit("key is not 2048-bit")
    return n


def cmd_keys(pem, out):
    n = read_modulus(pem)
    words = [(n >> (32 * i)) & 0xffffffff for i in range(64)]
    n0inv = (-pow(n, -1, 1 << 32)) & 0xffffffff
    R = 1 << (32 * 64)
    rr = (R * R) % n
    rrwords = [(rr >> (32 * i)) & 0xffffffff for i in range(64)]
    line = "{64,0x%08x,{%s},{%s}}" % (
        n0inv, ",".join(map(str, words)), ",".join(map(str, rrwords)))
    with open(out, "w") as fh:
        fh.write(line + chr(10))
    print("wrote", out, "(%d bytes)" % len(line))


def parse_keys(path):
    s = open(path).read().strip()
    m = re.match(r"[{]([0-9]+),0x([0-9a-fA-F]+),[{]([0-9,]+)[}],[{]([0-9,]+)[}][}]", s)
    if not m:
        raise SystemExit("unrecognised /res/keys format")
    nw = [int(x) for x in m.group(3).split(",")]
    n = sum(w << (32 * i) for i, w in enumerate(nw))
    n0inv = int(m.group(2), 16)
    if n0inv != ((-pow(n, -1, 1 << 32)) & 0xffffffff):
        raise SystemExit("n0inv mismatch in key file")
    return n, 3  # v1 key -> exponent 3


def clean_zip(data):
    idx = data.rfind(EOCD_MAGIC)
    if idx < 0:
        raise SystemExit("no EOCD found")
    if idx + EOCD_HEADER_SIZE + 2 == len(data):
        return data
    data = data[:idx + EOCD_HEADER_SIZE]
    struct.pack_into("<H", data, idx + 20, 0)
    return data


def cmd_sign(src, pem, dst, halg):
    data = clean_zip(bytearray(open(src, "rb").read()))
    data = bytes(data)
    signed = data[:-2]
    with tempfile.NamedTemporaryFile(delete=False) as tf:
        tf.write(signed)
        tmp = tf.name
    try:
        sig = subprocess.check_output(
            ["openssl", "dgst", "-" + halg, "-sign", pem, tmp])
    finally:
        os.unlink(tmp)
    if len(sig) != RSANUMBYTES:
        raise SystemExit("unexpected signature length %d" % len(sig))
    footer = struct.pack("<HHH", COMMENT_SIZE, 0xffff, COMMENT_SIZE)
    body = data[:-2] + struct.pack("<H", COMMENT_SIZE)
    out = body + sig + footer
    if out.find(EOCD_MAGIC, len(body) - 20) > 0:
        raise SystemExit("signature contains a stray EOCD magic; re-sign")
    open(dst, "wb").write(out)
    print("signed %s -> %s (%s, %d bytes)" % (src, dst, halg, len(out)))


def cmd_verify(src, keys, halg):
    n, e = parse_keys(keys)
    d = open(src, "rb").read()
    footer = d[-FOOTER_SIZE:]
    sig_start = struct.unpack_from("<H", footer, 0)[0]
    comment_size = struct.unpack_from("<H", footer, 4)[0]
    assert footer[2] == 0xff and footer[3] == 0xff, "bad footer marker"
    assert sig_start == COMMENT_SIZE and comment_size == COMMENT_SIZE, "bad footer sizes"
    eocd = d[-(comment_size + EOCD_HEADER_SIZE):]
    assert eocd[:4] == EOCD_MAGIC, "bad EOCD"
    signed_len = len(d) - comment_size - 2
    digest = hashlib.new(halg, d[:signed_len]).digest()
    sig = d[-FOOTER_SIZE - RSANUMBYTES:-FOOTER_SIZE]
    em = pow(int.from_bytes(sig, "big"), e, n).to_bytes(RSANUMBYTES, "big")
    di = DIGEST_INFO[halg] + digest
    pad = bytes([0xff]) * (RSANUMBYTES - 3 - len(di))
    expected = bytes([0x00, 0x01]) + pad + bytes([0x00]) + di
    print("verify %s (%s): %s" % (src, halg, "OK" if em == expected else "FAILED"))
    return 0 if em == expected else 1


def main():
    ap = argparse.ArgumentParser()
    sub = ap.add_subparsers(dest="cmd", required=True)
    p = sub.add_parser("keygen"); p.add_argument("pem")
    p = sub.add_parser("keys"); p.add_argument("pem"); p.add_argument("out")
    for name in ("sign", "verify"):
        p = sub.add_parser(name)
        p.add_argument("zip")
        p.add_argument("second")
        p.add_argument("out", nargs="?")
        p.add_argument("--hash", default="sha1", choices=["sha1", "sha256"])
    a = ap.parse_args()
    if a.cmd == "keygen":
        cmd_keygen(a.pem)
    elif a.cmd == "keys":
        cmd_keys(a.pem, a.out)
    elif a.cmd == "sign":
        cmd_sign(a.zip, a.second, a.out, a.hash)
    elif a.cmd == "verify":
        sys.exit(cmd_verify(a.zip, a.second, a.hash))


if __name__ == "__main__":
    main()
