# AGENTS.md — 本仓库协作规则

本文件是仓库级约定，所有在此仓库工作的 agent / assistant **开工前都要遵守**。
来源：`user-pref` 的生效偏好（`get_effective_preferences`）+ 本项目的历史教训。
本文件会被推送到公开远端，因此**自身不得含任何本机绝对路径 / 用户名 / 隐私信息**。

## 1. 语言
- 用中文回复（`coding.language = zh-CN`）；代码、标识符、命令保持英文。

## 2. 临时文件与删除（重点：避免权限拦截）
- 临时 / 中间产物**一律放项目内 `TMP/`**（已被 `.gitignore` 排除，不入库）。
- **不要访问仓库之外的目录**作为工作区，尤其系统临时目录（`/tmp` 等）、其他挂载卷。
- 目录不存在就创建（`create_if_missing`）。
- **禁用删除类命令**：`rm -rf`、`rm`、批量删除、`git clean`、以及一切"清理"动作。
  这些会触发权限提示/警告、打断会话、浪费时间（本机已多次因此被拦）。
  - 需要"干净"的临时目录时，**新建一个唯一目录名**（例如带时间戳），
    而不是"先删再建"：用 `mkdir -p TMP/<name>-$(date +%s)`。
  - 不删用户文件、不动未跟踪的备份/镜像、不清 git 工作区。
  - 例外：CI 脚本内部对自身 gitignored 构建目录（`build/`、`dist/`）的重置，
    属于 GitHub runner 上的脚本行为，不是本地交互操作，不受此约束。

## 3. 时间戳
- 每个命令 / 动作前打印当前时间：`date '+%Y-%m-%d %H:%M:%S %Z'`，
  便于事后追溯"何时做了什么"。

## 4. Git 工作流
- 每个小改动**立即 commit + push**（`workflow.git.commit_and_push_each_change`），
  避免丢失改动、避免堆积大 diff。
- 提交前**显式 `git add <具体路径>`**；**绝不用** `git add -A` / `git add .`
  （本仓库有未跟踪的备份镜像等大文件，曾误提交）。
- 提交后用 `git show --stat --oneline HEAD` 核对 staged 内容。
- commit message（`workflow.git.commit_message_style`）：
  - 遵循本仓库近期提交的 conventional 前缀风格（`feat:` / `fix:` / `docs:` / `ci:` …），
    参考最近约 10 个提交；
  - **禁止任何 trailer，尤其 `Co-authored-by`**。
- feature 完成后发 GitHub release 以触发 CI（`workflow.github.release_after_feature`）。

## 5. 隐私红线
- 推送到远端的**任何内容**——代码、文档、脚本、commit message——
  **不得出现本机绝对路径、本机用户名或任何可识别本机的信息**。
- 描述本地资源一律用相对路径或通用占位，例如
  "项目内 `TMP/` 目录"、"本地外置盘，未入库"。
- 提交前用检索工具检查：以 `/` 开头的本机用户主目录 / 挂载卷绝对路径，
  以及任何本机用户名；发现即改为相对路径或通用占位。

## 6. 构建
- **不在本地构建 rootfs / 系统镜像**（`mke2fs` / `debootstrap` / 生成 ext4 sparse /
  打包整个 rootfs 镜像），这类耗时且不可复现；打包与构建一律交 GitHub Actions CI。
- 本地只做毫秒级轻量校验：`bash -n`、CRC32、env 解析、sparse 头结构、
  zip 文件清单、YAML 语法。
- 想验证完整构建就改 workflow、提交、触发 CI，去 release 看产物和日志。
- 下载 release 产物时可走本机代理 + `aria2c`；但对**动态生成、无 Content-Length、
  不支持 Range** 的响应（如 codeload 源码 tarball），`aria2c` 多段会立刻失败，
  应改用单连接 `curl` 或 `git` 协议（本项目曾两次栽在这里）。

## 7. 分支（本项目）
- `main`：稳定的 6.3-rc5 刷机链，`build-release.yml`，tag `build-<STAMP>`。
- `mainline-porting`：HISTB 上游（Linux 7.4-rc1 + quilt 补丁集）plan B 工作区，
  独立 `build-histb.yml`，push 到该分支即出包、tag `histb-<STAMP>`，
  **不需要合并到 main 再构建**，两条流水线互不干扰。
- 具体路线与流水线见 `MAINLINE-PORTING.md`、`docs/030`。
