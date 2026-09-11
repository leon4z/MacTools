# MacTools

**macOS 增强工具合集，让日常操作更顺手。**

A native macOS toolkit for Finder actions, mouse tuning, Hyper / Meh keys,
and application shortcuts. Built with Swift, SwiftUI and AppKit.

## 功能

| 模块 | 能力 |
| --- | --- |
| 访达右键增强 | 拷贝完整路径、校验后移动、新建文件、用工具打开；支持独立菜单 |
| 鼠标工具 | 普通滚轮平滑、速度、加速度、横纵反向；设备级指针速度与加速度 |
| Hyper／Meh | 触发键和单击行为可配置，支持左右辅助键、常用按键及组合键录制 |
| 应用快捷键 | 快捷键打开或切换应用；目标已在前台时再次按下会隐藏目标，回到之前的应用 |

应用设置提供各模块独立开关和一键停用。停用保留配置，并恢复本应用临时修改的输入参数。
鼠标工具面向普通鼠标；触控板和连续高精度滚动保持原样。

## 安装

要求 **Apple Silicon、macOS 26 或更新版本**。

从 [Releases](https://github.com/leon4z/MacTools/releases) 下载 ZIP，解压后将
`MacTools.app` 放入 `~/Applications` 或 `/Applications`，再启动。
在系统设置中授予辅助功能权限，按需要启用 Finder 扩展，然后在应用设置中重新检查。

**当前发布包使用固定自签名身份，没有 Apple Developer ID 签名或 Apple 公证。**
首次下载可能被 Gatekeeper 阻止；确认来自本仓库后，可在系统设置的“隐私与安全性”中允许打开。
无需关闭系统安全机制。首次安装或从旧临时签名版本迁移，可能需要重新授予辅助功能权限。
若旧配置提示无权读取，使用“应用设置 → 重新连接配置”，在系统选择器中确认原文件夹即可；原文件不会移动或覆盖。
固定身份用于保持后续版本的连续性，但不保证系统升级、用户重置权限或更换签名身份后权限仍保留。

避免同时启用多个工具来改写同一鼠标滚轮或按键。MacTools 不会自动退出其他工具或导入它们的配置。
Finder 扩展的可用范围取决于系统实际回调；某些目录可使用独立菜单。

## 更新

在“应用设置 → 应用更新”或 MacTools 菜单中选择“检查更新”。
可选自动检查，下载和安装由你确认。更新使用 [Sparkle](https://sparkle-project.org/)，
从 GitHub Releases 获取版本信息，并用内置公钥校验更新包的 Ed25519 签名。
更新包签名与 macOS 应用代码签名各自独立。

更新前会恢复本应用临时修改的鼠标和键盘参数；有文件移动任务时等待任务完成。
更新不会替换用户配置。首次接入更新机制的旧版本需要手动安装一次。

## 开发

安装 Xcode 或兼容的 Apple Swift 工具链后，在仓库根目录执行：

```sh
bash scripts/test.sh
MACTOOLS_SIGNING_IDENTITY=- bash scripts/build.sh
```

首次测试或构建会从 Sparkle 官方 Release 下载固定 **2.9.6** 版本并校验 SHA-256，缓存保存在忽略的 `local/`。
产物位于 `build/MacTools.app`。可用 `FRC_BUILD_DIR` 指定本项目 `local/` 内以 `/build` 结尾的目录。
`-` 表示临时签名，仅适合开发；频繁安装这种产物可能需要反复授权。

使用自己钥匙串中的固定代码签名身份进行本机安装：

```sh
MACTOOLS_SIGNING_IDENTITY="你的签名身份" bash scripts/install-local.sh
```

安装脚本正常退出旧应用、备份旧包、检查签名，并注册安装目录的 Finder 扩展。
维护者的默认安装身份为 `MacTools Local Signing`，不存在时安装应失败，不降级为临时签名。
图标原稿位于 `Resources/AppIcon-source.png`；重新打包执行 `python3 scripts/generate-icon.py`。

测试覆盖文件操作、配置、冲突与恢复、AppKit 滚动位移、线程启停和上游平滑引擎。
可选 `bash scripts/test-windowserver.sh` 需要测试应用的辅助功能权限；退出码 77 表示跳过。
自动测试不代表所有实体鼠标和键盘均已完成验收。

## 兼容与贡献

为了保留既有数据与系统集成，宿主仍使用 `local.leon.FinderRightClick`，扩展仍使用
`local.leon.FinderRightClick.Extension`，URL scheme 仍为 `finderrightclick`，旧配置容器继续兼容。
这些内部名称不应仅为重命名而修改。

欢迎通过 Issue 描述系统版本、鼠标型号、复现步骤和期望行为。请移除日志中的个人路径和配置，勿提交密钥。
输入功能的改动必须保留恢复机制和独立开关。默认测试不得改动真实 HID 配置。

发布步骤、证书与更新密钥维护见 [发布文档](docs/releasing.md)。

## 许可与来源

MacTools 自有代码使用 [MIT License](LICENSE)。
鼠标平滑核心复用 LinearMouse v0.11.4；更新使用 Sparkle 2.9.6。
完整来源与许可见 [第三方声明](THIRD_PARTY_NOTICES.md)，其他研究参考见 [开源参考](OPEN_SOURCE_REFERENCES.md)。
