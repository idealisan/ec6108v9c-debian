#!/usr/bin/env bash
# =============================================================================
#  scripts/make-recovery-flash-package.sh
#
#  组装「用 recovery-flasher 方案刷 6.x 主线内核 + Debian rootfs」的 U 盘刷机包。
#
#  与旧 make-community-flash-package.sh 的区别只在【刷机程序那一层】：
#    旧：U 盘根 bootargs.bin 是 hiboot 的 mmc write 刷机脚本（刷机时黑屏、无进度）
#    新：U 盘根 bootargs.bin 是 recovery 入口 (fatload recovery.img; bootm)，
#        由「原版 recovery 3.10 内核 + 自研终端式 flasher」按 flash.manifest
#        的绝对 LBA 刷写，刷机阶段 HDMI 有终端式进度日志（已真机验证）。
#  被刷内容不变：p2 runtime env / p5 logo / p6 主线 6.x uImage / p8 Debian
#  rootfs(sparse)，全部复用 make-community-flash-package.sh 产出的主线镜像。
#  LBA 与主线 flash 脚本完全一致（p2 0x800 / p5 0x5000 / p6 0x7000 / p8 0x31000）。
#  p1 fastboot 永不写。
#
#  前置（CI package job 保证）：
#    - bash scripts/make-community-flash-package.sh 已跑，产出
#      build/community-package/pkg/mv100/ 主线镜像 + 顶层旧 bootargs.bin
#    - 已装 clang / lld / python3 / zip（recovery-flasher/build.sh 需要）
#  本机不编译内核、不构造 rootfs/系统镜像；只复用已提交/已产出的文件。
#
#  Usage: bash scripts/make-recovery-flash-package.sh
#  可用环境变量覆盖：DIST / STAMP / PKG / STAGE / OUT
# =============================================================================
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "$0")/.." && pwd)
cd "$ROOT_DIR"

DIST=${DIST:-dist}
STAMP=${STAMP:-$(date -u +%Y%m%dT%H%M%SZ)}
PKG=${PKG:-build/community-package/pkg}
STAGE=${STAGE:-build/recovery-mainline-package}
OUT=${OUT:-$DIST/mv100-mdmo1g-mainline-recovery-flash-$STAMP.zip}

echo "[1/6] 检查前置主线镜像 (来自 make-community-flash-package.sh)"
for f in bootargs.bin logo.img hi_kernel.bin debian-root.ext4; do
  [ -s "$PKG/mv100/$f" ] || { echo "缺少 $PKG/mv100/$f（先跑 make-community-flash-package.sh）" >&2; exit 1; }
done

echo "[2/6] 生成 recovery.img + 顶层 bootargs.bin（recovery 入口）"
# 只编译 15KB 的 ARM 静态 flasher 并用仓库内 recovery-stock.img 重打包；
# 不做内核/rootfs 交叉编译。产物落在 TMP/recovery-flash-out/。
# build.sh 里 community fastboot 拷贝那一行在 CI 会因源文件缺失返回非0，
# 但 recovery.img/bootargs.bin 在那之前已生成，故容忍退出码并靠产物校验兜底。
bash recovery-flasher/build.sh >/dev/null || \
  echo "  (build.sh 返回非0，继续校验产物是否已生成)"
RF=TMP/recovery-flash-out
[ -s "$RF/recovery.img" ] || { echo "recovery.img 未生成" >&2; exit 1; }
[ -s "$RF/bootargs.bin" ] || { echo "bootargs.bin 未生成" >&2; exit 1; }

echo "[3/6] 组装 staging"
mkdir -p "$STAGE/mv100"
cp -f "$PKG/mv100/"* "$STAGE/mv100/"
cp "$RF/recovery.img" "$STAGE/recovery.img"
cp "$RF/bootargs.bin" "$STAGE/bootargs.bin"      # 覆盖旧 hiboot mmc write 刷机脚本
# community carrier：build.sh 若能拷来就带上；CI 无则跳过，README 说明 U 盘常驻。
if [ -s "$RF/fastboot.bin" ]; then cp "$RF/fastboot.bin" "$STAGE/fastboot.bin"; fi

echo "[4/6] 生成 flash.manifest（绝对 LBA，字节数取文件真实大小）"
hexsz() { printf '%x' "$(wc -c < "$1" | tr -d ' ')"; }
B_HEX=$(hexsz "$STAGE/mv100/bootargs.bin")
L_HEX=$(hexsz "$STAGE/mv100/logo.img")
K_HEX=$(hexsz "$STAGE/mv100/hi_kernel.bin")
cat > "$STAGE/flash.manifest" <<EOF
# 主线 6.x 内核 + Debian rootfs，由 recovery-flasher 按绝对 LBA 裸写 eMMC。
# 格式: <src> <lba-hex> <bytes-hex> <R|S>  (S=Android sparse, bytes 忽略)
# LBA 与 make-community-flash-package.sh 的 flashpartition* 完全一致。
# p1 fastboot 永不写（安全红线 + 短接触点 U 盘兜底依赖它）。
/usb/mv100/bootargs.bin 800 $B_HEX R
/usb/mv100/logo.img 5000 $L_HEX R
/usb/mv100/hi_kernel.bin 7000 $K_HEX R
/usb/mv100/debian-root.ext4 31000 0 S
EOF

echo "[5/6] README + SHA256SUMS"
cat > "$STAGE/README.txt" <<'EOF'
EC6108V9C (Hi3798MV100) -- MAINLINE 6.x + Debian, recovery-flasher U-disk package
================================================================================
This U-disk package flashes the MAINLINE 6.x kernel + Debian rootfs, but uses
the RECOVERY-FLASHER method instead of the old hiboot "mmc write" script:

  shorted power-on -> BootROM loads community fastboot.bin (U-disk root, KEEP IT)
  -> hiboot reads top-level bootargs.bin -> fatload recovery.img; bootm
  -> patched STOCK recovery 3.10 kernel lights HDMI and runs our terminal-style
     flasher: a scrolling "<number> <TEXT>" log (every stage visible, nothing
     hidden), then writes p2/p5/p6/p8 by ABSOLUTE LBA from flash.manifest
  -> stops at "6 DONE NO REBOOT". Power off, remove stick, boot normally
     -> mainline 6.x kernel boots from p6.

U-disk root:
  fastboot.bin     community carrier (KEEP - BootROM loads it on shorted boot;
                   this package never writes p1/eMMC fastboot)
  bootargs.bin     recovery entry env (fatload recovery.img; bootm)
  recovery.img     patched stock recovery boot.img (3.10 kernel + our flasher)
  flash.manifest   4 items, absolute LBA, R=raw / S=Android sparse
  mv100/           mainline kernel uImage, Debian rootfs(sparse), p2 runtime
                   env (8-partition mainline cmdline), p5 "Debian Linux" logo

flash.manifest (LBA identical to make-community-flash-package.sh):
  p2 runtime env   LBA 0x800     p5 logo      LBA 0x5000
  p6 mainline 6.x  LBA 0x7000    p8 rootfs    LBA 0x31000 (sparse)
  p1 fastboot NEVER written; p3/p4/p7 untouched.

BOOT DISPLAY (mainline 6.x) -- BEST EFFORT, NOT VERIFIED ON REAL HW:
  The kernel carries console=tty0 + fbcon=map:0 + clk_ignore_unused + a
  simplefb/hdmi-console handoff driver + pstore/ramoops. A static simplefb
  node is intentionally omitted (framebuffer base not measured; not guessed).
  Judge on real hardware with the three signals: "Debian Linux" logo (hiboot
  drew p5) / green band (kernel reached the HDMI driver) / an IP on the router
  (network up). If HDMI and SSH are both dark, pstore/ramoops keeps the panic
  log. The FLASH stage display (terminal log) is already HW-verified.

SAFETY / RECOVERY:
  - p1 fastboot never written; the shorted U-disk flow always re-flashes.
  - Community-format zip (legacy hiboot mmc write) is kept as a known-good
    fallback in the same release.
  - No flash.manifest => zero eMMC writes (flasher is display/diagnostic only).
EOF
python3 - "$STAGE" <<'PY'
import hashlib, os, sys
s = sys.argv[1]
files = ["bootargs.bin", "recovery.img", "fastboot.bin", "flash.manifest"]
files += ["mv100/" + f for f in sorted(os.listdir(os.path.join(s, "mv100")))]
with open(os.path.join(s, "SHA256SUMS.txt"), "w") as out:
    for f in files:
        p = os.path.join(s, f)
        if os.path.isfile(p):
            out.write("%s  %s\n" % (hashlib.sha256(open(p, "rb").read()).hexdigest(), f))
PY

echo "[6/6] 静态校验 + 打包"
python3 - "$STAGE" <<'PY'
import os, struct, sys, zlib
s = sys.argv[1]
d = open(os.path.join(s, "bootargs.bin"), "rb").read()
assert len(d) == 65536, "bootargs.bin size"
assert struct.unpack_from("<I", d, 0)[0] == (zlib.crc32(d[4:]) & 0xffffffff), "bootargs CRC"
assert b"recovery.img" in d and b"bootm" in d, "not a recovery entry"
assert b"mmc write" not in d, "still the old hiboot flash script"
assert open(os.path.join(s, "recovery.img"), "rb").read(8) == b"ANDROID!", "recovery.img not ANDROID!"
lines = [l for l in open(os.path.join(s, "flash.manifest")).read().splitlines()
         if l.strip() and not l.lstrip().startswith("#")]
assert len(lines) == 4, lines
lbas = []
for l in lines:
    t = l.split()
    src, lba, kind = t[0], int(t[1], 16), t[3]
    assert os.path.isfile(os.path.join(s, src.replace("/usb/", "", 1))), src
    assert lba != 0, "p1 must never be written"
    assert kind in ("R", "S")
    lbas.append(lba)
assert lbas == [0x800, 0x5000, 0x7000, 0x31000], lbas
print("   OK: recovery 入口 + CRC + ANDROID! + 4 项 LBA + p1 不写")
PY
mkdir -p "$(dirname "$OUT")"
( cd "$STAGE" && zip -q -r "$ROOT_DIR/$OUT" . )
echo "产出: $OUT"
ls -lh "$OUT"
