#!/usr/bin/env bash
# 离线生成多个 fb_base/几何候选内核（改 appended DTB 注入 simplefb 节点）
# 用法: bash TMP/ci-download/gen-fb-candidates.sh
# 输出: TMP/ci-download/candidates/ 下多个 hi_kernel_*.bin + manifest 片段 + 说明
# 本机只做 dtc/字节拼接（毫秒级），不编译内核/rootfs、不碰 U 盘 eMMC。
set -euo pipefail
# 本脚本位于 <repo>/scripts/，上一级即仓库根
ROOT_DIR=$(cd "$(dirname "$0")/.." && pwd)
cd "$ROOT_DIR"
export WORKDIR=${WORKDIR:-TMP/ci-download}
export KERNEL_IMG=${KERNEL_IMG:-$WORKDIR/extract/mv100/hi_kernel.bin}  # 6.3 主线内核
export DTS_SRC=${DTS_SRC:-$WORKDIR/hi_kernel.dts}          # dtc -I dtb 反编译得到
export DTB_OFF=${DTB_OFF:-0x6f20e8}                        # appended DTB 起始
export OUT="$WORKDIR/candidates"
mkdir -p "$OUT"

python3 - <<'PY'
import struct, subprocess, os, zlib
D=os.environ["WORKDIR"]; OUT=os.environ["OUT"]
KERNEL_IMG=os.environ["KERNEL_IMG"]; DTS_SRC=os.environ["DTS_SRC"]
DTB_OFF=int(os.environ["DTB_OFF"], 0)
base=open(KERNEL_IMG,"rb").read()
zimg=base[0x40:DTB_OFF]           # uImage 头之后的 zImage 前缀（保持不动）
dts=open(DTS_SRC).read()

# 候选：名称 -> (fb_base, width, height, stride, size, format)
# 地址来源见 docs/041/043 (0x3f6ce000), docs/021/040 (0x3C55C000),
# docs/048 reserve_mem (0x3FFFE000/0x3FBFD000/0x3F8FC000), 探测 (0x0fc54000)
CAND = [
  ("A_top_0x3f6ce000_1920", 0x3f6ce000, 1920,1080,7680, 0x1000000,"a8r8g8b8"),
  ("B_top_0x3C55C000_1920", 0x3C55C000, 1920,1080,7680, 0x1000000,"a8r8g8b8"),
  ("C_reserve_0x3FBFD000_1920", 0x3FBFD000,1920,1080,7680, 0x1000000,"a8r8g8b8"),
  ("D_reserve_0x3F8FC000_1920", 0x3F8FC000,1920,1080,7680, 0x1000000,"a8r8g8b8"),
  ("E_top_0x3FFFE000_1920", 0x3FFFE000, 1920,1080,7680, 0x1000000,"a8r8g8b8"),
  ("F_probe_0x0fc54000_1280", 0x0fc54000,1280, 720,5120, 0x1000000,"a8r8g8b8"),
  ("G_top_0x3f6ce000_1280", 0x3f6ce000, 1280, 720,5120, 0x1000000,"a8r8g8b8"),
  ("H_probe_0x0fc54000_1920",0x0fc54000,1920,1080,7680, 0x1000000,"a8r8g8b8"),
]

def build_dts(fb,w,h,stride,size,fmt):
    # 在 reserved-memory { 后插入 framebuffer 保留段；在根末尾插入 simplefb 节点
    fbmem = (f'\t\tfb_mem: framebuffer@{fb:08x} {{\n'
             f'\t\t\treg = <0x{fb:08x} 0x{size:x}>;\n'
             f'\t\t\tno-map;\n'
             f'\t\t\tstatus = "okay";\n'
             f'\t\t}};\n')
    # 插到 reserved-memory 的属性(ranges;)之后、第一个子节点(ramoops)之前
    s = dts.replace("\t\tranges;\n", "\t\tranges;\n"+fbmem, 1)
    node = (f'\tframebuffer@{fb:08x} {{\n'
            f'\t\tcompatible = "simple-framebuffer";\n'
            f'\t\treg = <0x{fb:08x} 0x{size:x}>;\n'
            f'\t\twidth = <{w}>;\n'
            f'\t\theight = <{h}>;\n'
            f'\t\tstride = <{stride}>;\n'
            f'\t\tformat = "{fmt}";\n'
            f'\t\tstatus = "okay";\n'
            f'\t}};\n')
    idx = s.rfind("\n};")           # 根节点最后的 };
    s = s[:idx+1] + node + s[idx+1:]
    return s

def repack(new_dtb):
    payload = zimg + new_dtb
    hdr = bytearray(base[:0x40])
    struct.pack_into(">I", hdr, 12, len(payload))              # size
    struct.pack_into(">I", hdr, 24, zlib.crc32(payload)&0xffffffff)  # data crc
    struct.pack_into(">I", hdr, 4, 0)                          # hcrc zero
    struct.pack_into(">I", hdr, 4, zlib.crc32(bytes(hdr))&0xffffffff) # hcrc
    return bytes(hdr) + payload

manifest=[]
for name,fb,w,h,stride,size,fmt in CAND:
    dts_path=OUT+"/"+name+".dts"; open(dts_path,"w").write(build_dts(fb,w,h,stride,size,fmt))
    dtb_path=OUT+"/"+name+".dtb"
    r=subprocess.run(["dtc","-I","dts","-O","dtb","-o",dtb_path,dts_path],
                     capture_output=True,text=True)
    if r.returncode!=0:
        print("  dtc FAIL",name,r.stderr[-300:]); continue
    ndtb=open(dtb_path,"rb").read()
    img=repack(ndtb)
    kh="hi_kernel_"+name+".bin"
    open(OUT+"/"+kh,"wb").write(img)
    # 校验：能被 dtc 反解、含 simple-framebuffer 字符串、uImage magic
    ok_magic=struct.unpack_from(">I",img,0)[0]==0x27051956
    dts_back=subprocess.run(["dtc","-I","dtb","-O","dts",dtb_path],capture_output=True,text=True)
    has_sfb="simple-framebuffer" in dts_back.stdout
    print(f"  {kh}: {len(img)} B magic={'OK' if ok_magic else 'BAD'} simplefb={'OK' if has_sfb else 'MISSING'}")
    manifest.append((name,kh,f"0x{fb:08x}",f"{w}x{h}"))

with open(OUT+"/CANDIDATES.txt","w") as f:
    f.write("EC6108V9C 主线 6.3 内核 fb_base 候选（离线改 DTB 注入静态 simplefb）\n")
    f.write("内核 zImage 与 /chosen bootargs 不变，仅新增 simple-framebuffer 节点。\n")
    f.write("逐个试：把某个 hi_kernel_*.bin 复制到 U 盘 mv100/hi_kernel.bin 覆盖，\n")
    f.write("恢复 flash.manifest（把 .armed 改回 flash.manifest），短接刷一次。\n\n")
    for name,kh,fb,geo in manifest:
        f.write(f"  {name}: {kh}  fb_base={fb}  几何={geo}\n")
    f.write("\n判据：断电开机看绿带/启动文字/路由器新IP。哪个出画面就用哪个。\n")
    f.write("全部无画面 => 内核可能没起来，问题在启动链而非显存地址。\n")
print("  -> 候选清单:",OUT+"/CANDIDATES.txt")
PY
echo "=== 生成结果 ==="
ls -la "$OUT"/hi_kernel_*.bin | awk '{print "  "$5" B  "$NF}'
echo
cat "$OUT/CANDIDATES.txt"