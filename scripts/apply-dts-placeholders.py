#!/usr/bin/env python3
"""Substitute build-time placeholders in the EC6108V9C board DTS.

Usage: apply-dts-placeholders.py DTS_FILE SNIPPET [FB_BASE] [CMDLINE] [MEM_SIZE]

Placeholders:
  __FB_BLOCK__   standalone line replaced by the simple-framebuffer node
                 block (removed entirely when FB_BASE is unset)
  __FB_BASE__    framebuffer physical address
  __FB_STATUS__  "okay" / "disabled"
  __CMDLINE__    kernel command line (/chosen/bootargs)
  __MEM_SIZE__   DDR size for the /memory node

Only whole lines are substituted for the block, so a token that also shows up
inside a comment can never comment out the injected nodes.
"""
import sys

dts = sys.argv[1]
snippet = sys.argv[2]
fb_base = sys.argv[3] if len(sys.argv) > 3 else ''
cmdline = sys.argv[4] if len(sys.argv) > 4 else ''
mem_size = sys.argv[5] if len(sys.argv) > 5 else '0x40000000'
NL = chr(10)


def inject_block(text, body):
    out = []
    for line in text.splitlines(True):
        if line.strip() == '__FB_BLOCK__':
            out.append(body)
        else:
            out.append(line)
    return ''.join(out)


d = open(dts).read()
if fb_base:
    body = open(snippet).read()
    body = body.replace('EC6108_FB_NAME', fb_base.replace('0x', ''))
    body = body.replace('EC6108_FB_BASE', fb_base)
    body = body.replace('EC6108_FB_STATUS', '"okay"')
    d = inject_block(d, body.rstrip(NL) + NL)
    d = d.replace('__FB_BASE__', fb_base)
    d = d.replace('__FB_STATUS__', '"okay"')
    print('framebuffer enabled at ' + fb_base)
else:
    d = inject_block(d, '')
    d = d.replace('__FB_BASE__', '0x3d000000')
    d = d.replace('__FB_STATUS__', '"disabled"')
    print('framebuffer nodes omitted (FB_BASE unset)')

d = d.replace('__CMDLINE__', cmdline)
d = d.replace('__MEM_SIZE__', mem_size)
open(dts, 'w').write(d)
print('cmdline: ' + (cmdline or '(empty)'))
print('memory : ' + mem_size)
