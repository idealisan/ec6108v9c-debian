================================================================
 EC6108V9C Debian U盘刷机操作卡
 release: build-20261107T070813Z
 本文件只是说明，hiboot 不会读取它，可以留在U盘根目录
================================================================

【重要勘误 / 以本卡为准】
  本目录里自带的 README.txt 是旧文案，其中
      "debian-root.ext4 -> p9"
      "9-partition blkdevparts layout matches the community image"
  这两句已经过时。实际产物是：
      rootfs 写入 LBA 0x31000 (98M) = 新布局的 p8
      运行时 cmdline: root=mmcblk0p8 + 8 分区 blkdevparts (-(debian))
  请以 mv100/README.txt 和 mv100/bootargs.bin 为准。

【U盘准备】
  1. U盘格式化为 MBR + FAT32，单个主分区
  2. 把本目录(dist/usb-flash-ready)里的【全部内容】拷到U盘根目录，
     保持 mv100/ 子目录结构不变：
        U盘:\
          bootargs.bin          <- 顶层刷机脚本(CRC32头)
          HOWTO-FLASH.txt       <- 本说明(可留)
          README.txt            <- 包内旧说明(可留, 见上方勘误)
          SHA256SUMS.txt        <- 包内校验
          mv100\
            bootargs.bin        <- 运行时环境变量(root=mmcblk0p8) -> p2
            hi_kernel.bin       <- 内核 uImage -> p6
            debian-root.ext4   <- Debian rootfs(Android sparse) -> p8
            README.txt
  3. 确认 mv100/ 下 4 个文件齐全

【刷机】
  1. 盒子断电
  2. 插U盘
  3. 短接触点(与社区包相同的触发方式)，保持短接上电
  4. hiboot 读顶层 bootargs.bin，依次写 p6/p8/p2，约1分钟后自动 reset
  5. 第一次重启后拔掉U盘，再断电重开一次

【登录与验证】
  ssh root@<IP>        密码 ec6108v9c
  第一件事: passwd 改密码
  uname -a
  ec6108-temp
  ec6108-fbprobe        -> 把 "FB-like" 那几行发出来，用于点亮 HDMI

【安全 / 兜底】
  - 本包从不写 p1(hiboot)，U盘救援通道始终保留
  - 如果刷完起不来：用社区原版包
      本机工作目录里的社区原版包 mv100-mdmo1g-usb-flash.zip
    (该文件在项目目录之外，按要求没有动它，需要时自行取用)
    用同样的短接触点方法重刷即可恢复成社区 Ubuntu
  - 恢复后如需定位内核问题：把诊断内核 dd 到 p6 重启，
    SSH 进社区系统看 dmesg，无需再碰 U盘

【附带材料(不放进U盘)】
  ../flash-support/
    hi_kernel.bin                  主内核, 后续 dd 更新用
    hi_kernel-community-layout.bin 诊断内核(root=p9, 带社区 rootfs 启动)
    SHA256SUMS.txt                 release 级校验
    debian-rootfs-armhf-bookworm.tar.gz / modules.tar.gz (可选)
