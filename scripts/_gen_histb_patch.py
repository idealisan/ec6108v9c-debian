#!/usr/bin/env python3
import os, re
K='third_party/linux-hi3798mv100'
SRC='TMP/histb-backport/extracted'
PAT='TMP/histb-backport'
OUT=PAT+'/0006-histb-drm-display-backport.patch'

def newfile(f):
    data=open(os.path.join(SRC,f)).read().splitlines(True)
    p=['diff --git a/%s b/%s\n'%(f,f),'new file mode 100644\n','--- /dev/null\n','+++ b/%s\n'%f,
       '@@ -0,0 +1,%d @@\n'%len(data)]
    p += [('+'+ln if ln.endswith('\n') else '+'+ln+'\n\\ No newline at end of file\n') for ln in data]
    return p

def original_hunks(patchfile, targets):
    """Extract, from an original histb patch, the full diff sections for target files."""
    lines=open(patchfile).read().splitlines(True)
    out=[]; keep=False
    for ln in lines:
        if ln.startswith('diff --git '):
            m=re.search(r' b/(\S+)',ln)
            f=m.group(1) if m else ''
            keep = f in targets
        if keep: out.append(ln)
    return out

files=[
 'drivers/gpu/drm/histb/Kconfig','drivers/gpu/drm/histb/Makefile',
 'drivers/gpu/drm/histb/histb-vdp.h','drivers/gpu/drm/histb/histb-vdp-core.c',
 'drivers/gpu/drm/histb/histb-vdp2-regs.h','drivers/gpu/drm/histb/histb-vdp2.c',
 'drivers/gpu/drm/bridge/sii9134.h','drivers/gpu/drm/bridge/sii9134.c',
 'drivers/gpu/drm/bridge/hi3798mv100-hdmi.c','drivers/regulator/histb-regulator.c',
]
parts=[]
for f in files: parts+=newfile(f)
import difflib
# drm core Kconfig/Makefile: append source/obj (simple, verified absent)
def append(f,line):
    path=os.path.join(K,f); orig=open(path).read().splitlines(True); new=list(orig)
    if new and not new[-1].endswith('\n'): new[-1]+='\n'
    new.append(line+'\n')
    return list(difflib.unified_diff(orig,new,fromfile='a/'+f,tofile='b/'+f,n=3))
parts+=append('drivers/gpu/drm/Kconfig','source "drivers/gpu/drm/histb/Kconfig"')
parts+=append('drivers/gpu/drm/Makefile','obj-$(CONFIG_DRM_HISTB_VDP) += histb/')

# bridge/Kconfig: define DRM_SII9134 (critical: without this the config is
# dropped by olddefconfig and sii9134.ko never builds -> VDP never binds -> black screen)
# Generate against the REAL 6.3 file (not the 7.4 original hunk, whose line
# numbers never matched and were silently skipped).
def insert_before(f, anchor, block):
    path=os.path.join(K,f); orig=open(path).read().splitlines(True); new=list(orig)
    idx=next(i for i,l in enumerate(new) if l.startswith(anchor))
    new[idx:idx]=block
    return list(difflib.unified_diff(orig,new,fromfile='a/'+f,tofile='b/'+f,n=3))
def insert_after_line(f, needle, block):
    path=os.path.join(K,f); orig=open(path).read().splitlines(True); new=list(orig)
    idx=next(i for i,l in enumerate(new) if needle in l)+1
    new[idx:idx]=block
    return list(difflib.unified_diff(orig,new,fromfile='a/'+f,tofile='b/'+f,n=3))
parts+=insert_before('drivers/gpu/drm/bridge/Kconfig','config DRM_SII9234',
    ['config DRM_SII9134\n','\ttristate "Silicon Image SiI9134 HDMI 1.4 transmitter"\n',
     '\tdepends on OF\n','\tselect DRM_KMS_HELPER\n','\tselect REGMAP\n','\thelp\n',
     '\t  HDMI 1.4 transmitter (SiI9134 core) integrated on HiSilicon Hi3798MV100.\n',
     '\t  drm_bridge component needed by histb-vdp KMS driver to drive HDMI.\n','\n'])
# bridge/Makefile: build sii9134.o + hi3798mv100-hdmi.o
parts+=insert_after_line('drivers/gpu/drm/bridge/Makefile','obj-$(CONFIG_DRM_SII902X)',
    ['obj-$(CONFIG_DRM_SII9134) += sii9134-hdmi.o\n',
     'sii9134-hdmi-y := sii9134.o hi3798mv100-hdmi.o\n'])
open(OUT,'w').writelines(parts)
print('wrote',OUT,os.path.getsize(OUT),'bytes')
