#!/usr/bin/env python3
"""Substitute build-time placeholders in the EC6108V9C board DTS.

Usage: apply-dts-placeholders.py DTS_FILE SNIPPET [FB_BASE] [CMDLINE] [MEM_SIZE]

Placeholders:
  __FB_BLOCK__   standalone line replaced by the pstore ramoops node plus,
                 when FB_BASE is set, the simple-framebuffer node block
  __FB_BASE__    framebuffer physical address
  __FB_STATUS__  "okay" / "disabled"
  __CMDLINE__    kernel command line (/chosen/bootargs)
  __MEM_SIZE__   DDR size for the /memory node

Framebuffer geometry comes from the environment so it can be set from CI
inputs once measured on the box (FB_WIDTH / FB_HEIGHT / FB_STRIDE /
FB_FORMAT / FB_SIZE). Width/height/stride/format are the SDK-confirmed
1080p ARGB8888 values (docs/040); FB_SIZE defaults to 0x1000000 (16 MiB) to
cover the double-buffered scan-out region (two 1080p frames) that the VO
scans, while the simplefb node still declares a single 1080p frame via
<height>. The driver's runtime hand-off path (hi3798mv100-hdmi-console.c)
is independent of this static node and discovers the buffer from VO regs.

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
    # docs/040: the VO scans a double-buffered region (2 x 1920x1080x4 =
    # 0xFD0000 B). Reserve both frames; simplefb/fbcon draws one 1080p frame.
    'EC6108_FB_SIZE': os.environ.get('FB_SIZE') or '0x1000000',
}


def inject_block(text, body):
    out = []
    for line in text.splitlines(True):
        if line.strip() == '__FB_BLOCK__':
            out.append(body)
        else:
            out.append(line)
    return ''.join(out)


# ramoops is always injected: it is the only log channel that survives a
# boot where neither HDMI nor SSH comes up. The snippet holds just the
# ramoops child node; both paths place it inside a single reserved-memory
# container so there is never a duplicate "reserved-memory" node.
ramoops_snippet = os.path.join(os.path.dirname(snippet), 'ramoops.dtsi')
ramoops_child = open(ramoops_snippet).read().rstrip(NL) + NL

d = open(dts).read()
if fb_base:
    body = open(snippet).read()
    body = body.replace('EC6108_FB_NAME', fb_base.replace('0x', ''))
    body = body.replace('EC6108_FB_BASE', fb_base)
    body = body.replace('EC6108_FB_STATUS', '"okay"')
    for key, val in FB_GEOM.items():
        body = body.replace(key, val)
    body = body.replace('__RAMOOPS_CHILD__', ramoops_child.rstrip(NL))
    d = inject_block(d, body.rstrip(NL) + NL)
    d = d.replace('__FB_BASE__', fb_base)
    d = d.replace('__FB_STATUS__', '"okay"')
    print('framebuffer enabled at ' + fb_base + ' '
          + FB_GEOM['EC6108_FB_WIDTH'] + 'x' + FB_GEOM['EC6108_FB_HEIGHT']
          + ' stride=' + FB_GEOM['EC6108_FB_STRIDE']
          + ' format=' + FB_GEOM['EC6108_FB_FORMAT'] + '; ramoops enabled')
else:
    container = ('\treserved-memory {' + NL +
                 '\t\t#address-cells = <1>;' + NL +
                 '\t\t#size-cells = <1>;' + NL +
                 '\t\tranges;' + NL +
                 ramoops_child +
                 '\t};' + NL)
    d = inject_block(d, container)
    d = d.replace('__FB_BASE__', '0x3d000000')
    d = d.replace('__FB_STATUS__', '"disabled"')
    print('framebuffer nodes omitted (FB_BASE unset); pstore ramoops enabled')

d = d.replace('__CMDLINE__', cmdline)
d = d.replace('__MEM_SIZE__', mem_size)
open(dts, 'w').write(d)
print('cmdline: ' + (cmdline or '(empty)'))
print('memory : ' + mem_size)
