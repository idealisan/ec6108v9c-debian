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

Framebuffer geometry comes from the environment so it can be set from CI
inputs once measured on the box (FB_WIDTH / FB_HEIGHT / FB_STRIDE /
FB_FORMAT / FB_SIZE). Defaults are the SDK-confirmed 1080p ARGB8888 values.

Only whole lines are substituted for the block, so a token that also shows up
inside a comment can never comment out the injected nodes.
"""
import os
import sys

dts = sys.argv[1]
snippet = sys.argv[2]
fb_base = sys.argv[3] if len(sys.argv) > 3 else ''
cmdline = sys.argv[4] if len(sys.argv) > 4 else ''
mem_size = sys.argv[5] if len(sys.argv) > 5 else '0x40000000'
NL = chr(10)

FB_GEOM = {
    'EC6108_FB_WIDTH': os.environ.get('FB_WIDTH') or '1920',
    'EC6108_FB_HEIGHT': os.environ.get('FB_HEIGHT') or '1080',
    'EC6108_FB_STRIDE': os.environ.get('FB_STRIDE') or '7680',
    'EC6108_FB_FORMAT': os.environ.get('FB_FORMAT') or 'a8r8g8b8',
    'EC6108_FB_SIZE': os.environ.get('FB_SIZE') or '0x800000',
}


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
    for key, val in FB_GEOM.items():
        body = body.replace(key, val)
    d = inject_block(d, body.rstrip(NL) + NL)
    d = d.replace('__FB_BASE__', fb_base)
    d = d.replace('__FB_STATUS__', '"okay"')
    print('framebuffer enabled at ' + fb_base + ' '
          + FB_GEOM['EC6108_FB_WIDTH'] + 'x' + FB_GEOM['EC6108_FB_HEIGHT']
          + ' stride=' + FB_GEOM['EC6108_FB_STRIDE']
          + ' format=' + FB_GEOM['EC6108_FB_FORMAT'])
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
