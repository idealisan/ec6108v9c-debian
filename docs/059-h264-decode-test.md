# 059 — 7.4 内核 H.264 解码能力实测

> 2026-11-19。测试机：7.4-rc2 包 `build-20261119T014037Z`，软件渲染模式下运行。
> 目标：确认新内核是否带上了 Hi3798MV100 的 H.264 硬件解码（V4L2 M2M）。

## 1. 片源与工具

- 片源：Big Buck Bunny，1080p H.264 High profile，**10 秒 / 600 帧 / 60fps / 832 kb/s**
  （`test-videos.co.uk` 的 1MB 短片，便于在 1GB 内存机器上测试）。
- 工具：Debian bookworm `ffmpeg 5.1.9-0+deb12u1`（armhf），经 SSH 转发代理安装。
- sha256：`38d763af0161e28145e6300d9a5b3b1e4a387ed8f6c4ba7ac1a5f2948d8fac51`。

## 2. 设备与驱动现状（当前包）

| 检查项 | 结果 |
|---|---|
| `/dev/video*` | **不存在** |
| `v4l2-ctl --list-devices` | `Cannot open device /dev/video0` |
| `lsmod` 中 histb/vdec/vpss | 无 |
| `/lib/modules/*` 中 `histb*`/`vdec*`/`vpss*` | 无（只有无关的 `s5p-jpeg.ko`） |
| 内核命令行/config | 当前包未启用 `VIDEO_HISTB_VDEC/VENC/VPSS/JPGD/JPGE` |

结论：**媒体驱动补丁已在 `patches/histb/` 里，但 `configs/kernel/ec6108v9c.config` 没有启用**，
所以 `olddefconfig` 后这些驱动为 N，编译出的内核没有任何 V4L2 M2M 设备。

## 3. ffmpeg 实测

```
$ ffmpeg -hwaccels
vdpau vaapi drm opencl vulkan            ← 没有 v4l2m2m

$ ffmpeg -hwaccel v4l2m2m -i bbb.mp4 -f null -
Unrecognized hwaccel: v4l2m2m

$ ffmpeg -c:v h264_v4l2m2m -i bbb.mp4 -f null -
[h264_v4l2m2m] Could not find a valid device
[h264_v4l2m2m] can't configure decoder
Error while opening decoder for input stream #0:0 : Invalid argument
```

软件解码基线（1080p60，10 秒片）：

```
frame=600 fps=34 ... speed=0.571x
real 18.853s   user 60.003s   sys 1.800s
```

即约 34 fps 解码吞吐：对 1080p60 只有 0.57x（不能实时），
若换成 1080p30 大致刚好实时，1080p24 可实时。

## 4. 结论与下一步

- **当前 7.4 刷机包不支持 H.264 硬件解码**，只能软件解码。
- 不是内核源码缺失：`patches/histb/` 已引入 `VIDEO_HISTB_VDEC/VENC/VPSS/JPGD/JPGE`
  等 V4L2 M2M 驱动，板级 DTS 节点也都在（`810-03`）。
- 修复路径就是 `docs/056` 的 **P2**：在 `configs/kernel/ec6108v9c.config` 显式启用这些符号，
  并在 `scripts/build-kernel.sh` 的 `olddefconfig` 后硬断言；重跑 CI 出包、重刷，再验证
  `/dev/video*` 出现且 `ffmpeg -c:v h264_v4l2m2m` 可用。
- 注意 GPU 桌面是软件渲染（llvmpipe），软解 + 4K 桌面会明显抢占 CPU；测解码建议在 1080p 下做。

## 5. 相关

- `docs/056-7.4-driver-bringup-plan.md`：P2 补齐 config 缺口（含精确符号清单）
- `docs/058-7.4-first-hw-verify.md`：真机启动/GPU/4K 验证记录
