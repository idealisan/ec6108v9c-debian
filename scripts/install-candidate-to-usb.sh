#!/usr/bin/env bash
# U 盘插回电脑后运行：把指定候选内核装成 mv100/hi_kernel.bin 并核对盘面。
# 用法: bash scripts/install-candidate-to-usb.sh B [USB_MOUNT]
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
L=${1:-B}; USB=${2:-/Volumes/BOXBAK}
C="$ROOT/TMP/ci-download/candidates"
[ -d "$USB" ] || { echo "U 盘未挂载: $USB"; exit 1; }
SRC=$(ls "$C"/hi_kernel_${L}_*.bin | head -1)
cp "$SRC" "$USB/mv100/hi_kernel.bin"
# manifest 用该内核真实大小（候选都一样，固定 6f58c0）
python3 - "$USB" <<'PY'
import sys,os
u=sys.argv[1]
sz=os.path.getsize(u+"/mv100/hi_kernel.bin")
p=u+"/flash.manifest"
lines=open(p).read().splitlines(); out=[]
for l in lines:
    if l.strip().startswith("/usb/mv100/hi_kernel.bin"):
        t=l.split(); l="%s %s %x %s"%(t[0],t[1],sz,t[3])
    out.append(l)
open(p,"w").write("\n".join(out)+"\n")
import hashlib
print("  hi_kernel.bin size 0x%x, sha256 %s"%(sz,hashlib.sha256(open(u+"/mv100/hi_kernel.bin","rb").read()).hexdigest()[:16]))
PY
echo "  已装候选 $L: $(basename "$SRC")"
echo "  manifest 项数与 bytes 已核对；插到设备短接刷即可。"
