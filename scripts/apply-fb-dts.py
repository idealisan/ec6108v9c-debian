#!/usr/bin/env python3
"""Substitute the framebuffer placeholder in the EC6108V9C DTS.

Usage: apply-fb-dts.py DTS_FILE SNIPPET [FB_BASE]

If FB_BASE is empty, the placeholder block is removed entirely (so no bogus
reserved-memory is created). Otherwise the simple-framebuffer nodes are
inserted and the macros are expanded.
"""
import sys

dts = sys.argv[1]
snippet = sys.argv[2]
base = sys.argv[3] if len(sys.argv) > 3 else ''
NL = chr(10)
d = open(dts).read()
if base:
    body = open(snippet).read() \
        .replace('EC6108_FB_BASE', base) \
        .replace('EC6108_FB_STATUS', '"okay"')
    d = d.replace('__FB_BLOCK__', body.rstrip(NL)) \
         .replace('__FB_BASE__', base).replace('__FB_STATUS__', '"okay"')
    print('framebuffer enabled at ' + base)
else:
    d = d.replace('__FB_BLOCK__', '') \
         .replace('__FB_BASE__', '0x3d000000') \
         .replace('__FB_STATUS__', '"disabled"')
    print('framebuffer nodes omitted (FB_BASE unset)')
open(dts, 'w').write(d)
