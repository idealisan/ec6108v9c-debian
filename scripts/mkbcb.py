#!/usr/bin/env python3
"""Build a bootloader_message (BCB) that boots recovery with an OTA argument.

struct bootloader_message {
    char command[32];
    char status[32];
    char recovery[768];
    char stage[32];
    char reserved[224];
};  // 1088 bytes, at offset 0 of the misc partition

get_args() reads boot.recovery, requires the first token to be "recovery",
and treats the following lines as argv. This bypasses the Huawei recovery menu
and the /usb/upgrade package-name whitelist entirely.

Usage: mkbcb.py OUT.bin [--update-package PATH]
"""
import argparse

ap = argparse.ArgumentParser()
ap.add_argument("out")
ap.add_argument("--update-package", default="/cache/recovery/update.zip")
a = ap.parse_args()

NL = chr(10)
b = bytearray(1088)  # already zero-filled
cmd = b"boot-recovery"
b[0:len(cmd)] = cmd
rec = ("recovery" + NL + "--update_package=" + a.update_package + NL).encode()
b[64:64 + len(rec)] = rec
open(a.out, "wb").write(b)
print("wrote %s: %d bytes" % (a.out, len(b)))
print("recovery field:", repr(rec))
