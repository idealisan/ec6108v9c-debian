# 原厂 recovery 反汇编核查（2026-11-04）

对象：p03 里的 sbin/recovery（445,036 字节，来自用户备份
ec6108v9c-stock-ROM-backup.zip 的 p03_recovery.img，8 MiB 偏移处是
标准 Android boot.img，ramdisk 为 gzip 的 newc cpio，52 个条目）。

## 1. 二进制形态

| 项 | 值 |
|---|---|
| ELF | ET_EXEC（非 PIE），ARM，静态链接，无 PT_DYNAMIC |
| 入口 | 0x80f8 |
| .text | 0x80f8..0x5c3dc（0x542e4），Thumb-2 为主，开头是 ARM |
| .rodata | 0x5f2b8..0x6f8a8 |
| .data.rel.ro.local / .got | 0x71280 / 0x72e7c，存放绝对指针 |
| 寻址 | PIC 风格：ldr rX,[pc,#imm] + add rX,pc 直接算出字符串地址；
          或先算 PIC base（约 0x72ff2）再 ldr rY,[rPic,rOff] 取 GOT 槽 |
| 函数边界 | .ARM.exidx 解出 1231 个函数地址 |

一开始按 ARM 模式线性反汇编全部落空：这个 binary 是 Thumb-2，且字符串
没有以绝对指针形式出现在 literal pool 里，而是用 add rX, pc 现算。
按 exidx 逐函数、按 Thumb 模式解析 ldr [pc] + add ,pc 后才定位到代码。

## 2. 签名链路

- /res/keys 字符串存在，load_keys() 用 mincrypt dumpkey v1 格式
  （{64,0x<n0inv>,{n[64]},{rr[64]}}，v1 隐含 exponent=3）。
- 原厂公钥没有硬编码：把 res/keys 的 256 字节模数（小端）拿去整个
  binary 里搜，命中 0 次。所以换掉 ramdisk 里的 /res/keys 就能换信任根。
- verify_file() 的打印串与 AOSP/CM 的 verifier.cpp 逐字相同：
  I:comment is %d bytes; signature %d bytes from end、
  E:signature is too short、E:signature length doesn't match EOCD marker、
  E:failed to verify whole-file signature、Installing update...、
  I:verify_file returned %d。
- 哈希确认是 SHA-1：E:failed to alloc memory for sha1 buffer
  （AOSP verifier.cpp 里 malloc(BUFFER_SIZE) 的报错串）。
  二进制里找不到 SHA-256 的 DigestInfo 或连续的 SHA-1/SHA-256 IV 常量表，
  说明用的是 mincrypt 的 SHA-1 + RSA_verify(key, sig, 256, sha1)。
- 签名格式：SHA-1(去掉 EOCD 注释长度 2 字节的整包) -> RSA-2048 PKCS#1 v1.5，
  256 字节签名放在 ZIP 注释末尾，后跟 6 字节 footer
  [sig_start=262][0xff][0xff][comment_size=262]。

## 3. 关键发现：华为自定义的白名单（会导致"升级失败"）

函数 0x9188..0xa14c（upgrade_direcotry / U 盘目录扫描）里逐条解析到：

    0x95cc  "find the zip file: %s"
    0x95ec  "THE FILENAME IS %s"
    0x9604  "E:#####print the package_name: %s"
    0x96d0  "E:This is different package, return INSTALL_NOPACKAGE"
    0x9868  "SDLT_EC6108V9"
    0x987c  "ZJDX_EC6108V9"
    0x988c  "SHDX_EC6108V9"
    0x989c  "YUANQU_EC6108V9"
    0x98b0  "SHYD_EC6108V9"
    0x9ed0  "GDDX_EC6108V9"
    0x5fd3e "ro.build.office"      （属性名）
    0x5fc4c "_TO_"                 （包名分隔符/版本区间）

典型片段（Thumb-2）：

    0x9862  ldr.w r0,[pc,#...] ; "SDLT_EC6108V9"
    0x9868  add   r0, pc
    0x986a  bl    0x540a8       ; 名字比较，返回 0 表示匹配
    0x986e  cbnz  r0, 0x9876   ; 不匹配就试下一个前缀
    ...
    0x9ed0  add   r0, pc       ; "GDDX_EC6108V9"
    0x9ed2  bl    0x540a8

结论：走 /usb/upgrade 目录扫描时，包名必须符合
<运营商前缀>_EC6108V9..._TO_... 这套命名，并且要和 ro.build.office
对应的前缀匹配；不匹配就 INSTALL_NOPACKAGE，报
"E:This is different package"。这解释了之前用 update.zip 提示"升级失败"——
除了签名之外还有这一道包名白名单。

## 4. 绕开白名单的入口

同一个二进制里也有标准 AOSP 入口：

    0x5f507  "--update_package="
    0x5f6d7  "/cache/recovery/command"
    0x5f4ef  "boot-recovery"
    0x5ff39  "/cache/update.zip"
    0x60b54  "/sdcard/update.zip"

--update_package=<path> 直接进 install_package() -> verify_file()，
不经过上面那个目录扫描函数，所以不受文件名白名单约束。
做法（Android root）：

    printf '%s' '--update_package=/usb/update.zip' > /cache/recovery/command
    reboot recovery

注意：字符串 I:/cache/update.zip is existed, we will delete it 表明
recovery 启动时会删 /cache/update.zip；因此包要放 /usb/update.zip
（U 盘）或 /cache/recovery/update.zip，别放 /cache/update.zip。

## 5. 对换公钥方案的结论

| 检查 | 结果 |
|---|---|
| 公钥是否只有 /res/keys 一处 | 是（二进制里没有硬编码模数） |
| load_keys 是否吃 v1 / e=3 | 是（格式逐字核对过，n0inv、R² 都能复算） |
| verify_file 用什么哈希 | SHA-1 |
| 额外的包名白名单 | 有，但只在 /usb/upgrade 扫描路径；--update_package 可绕开 |
| 额外的整包签名私钥 | 无 |

因此：p3_keyswap.img（只换 /res/keys）+ ota-sign.py 签出的
update-sha1.zip + --update_package 触发，是当前证据下最稳的组合。
update-sha256.zip 只是以防厂商改过哈希（目前证据指向 SHA-1）。

## 6. 仍未在真机验证的部分

- 华为是否在 main() 里强制先跑 upgrade_direcotry() 再处理
  --update_package（如果强制，就得把包按白名单命名）；
- RSA_verify 是否对 v1 key 之外还有别的 key 来源；
- install_package 是否有除 verify_file 之外的额外校验（如 zip 内
  META-INF/... 之外的华为私有文件要求）。
- ro.build.office 的实际值（可在 Android 里 getprop ro.build.office 查到），
  用于按白名单命名包。
