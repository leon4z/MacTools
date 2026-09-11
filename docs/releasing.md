# 发布与更新

本项目通过 GitHub Releases 发布源代码与 ZIP 安装包，使用 Sparkle 2 的原生界面检查、下载、验证和安装更新。
发布签名在维护者本机进行；CI 仅验证源码和开发构建，不接触发布私钥。

## 两套独立身份

- **应用代码签名**：维护者 login 钥匙串中的 `MacTools Local Signing`。当前自签名证书 SHA-1 为
  `793D0DA7BCBFB6A0CDC8569A9F3E7A3D78A0C688`。保持同一证书和 Bundle ID，以维持指定代码要求的连续性。
  这不等于 Apple Developer ID 签名、公证或 Gatekeeper 认可。
- **更新包签名**：Sparkle Ed25519 密钥，钥匙串账户 `com.leon4z.MacTools`。公钥固化在
  `Resources/AppInfo.plist` 的 `SUPublicEDKey` 中。包内容被篡改时应拒绝安装。

私钥仅存钥匙串，不提交、复制到构建目录或上传 GitHub Secrets。维护者应使用受保护的钥匙串/系统备份保护密钥；
丢失代码签名身份或更新签名密钥后不能直接生成新密钥冒充原身份。迁移必须按 Sparkle 官方密钥轮换机制规划，
必要时通过手动安装重新建立信任。Fork 应使用自己的密钥、证书、公钥及更新地址。

自签名证书可通过“钥匙串访问 → 证书助理”创建代码签名身份；只对代码签名用途设定所需信任，
不要全局信任不相关用途。首次从临时签名切换到证书签名，重新授权一次是预期的身份迁移。
未来 Developer ID 迁移需单独验收授权行为。

配置目录若因身份迁移暂时不可读，使用应用内“重新连接配置”经系统选择器重新授权原目录。
应用保存该目录的安全作用域书签，启动时先恢复访问；读取失败期间拒绝保存默认配置。
这与辅助功能授权分别处理，不应索取全盘访问权限，也不修改 TCC 或容器保护元数据。

## 常规发布

1. 修改 `Resources/AppInfo.plist` 的显示版本及递增 build；更新扩展版本使宿主和扩展保持一致。
   发布版本格式 `x.y.z`，标签 `vx.y.z`，build 必须严格递增。
2. 审查 diff、第三方许可和公开文件清单。禁止包含 `local/`、历史文档、日志、用户配置、密钥和 `.DS_Store`。
3. 执行测试与固定签名构建：

   ```sh
   bash scripts/test.sh
   MACTOOLS_SIGNING_IDENTITY=793D0DA7BCBFB6A0CDC8569A9F3E7A3D78A0C688 bash scripts/build.sh
   python3 scripts/package-release.py
   ```

   打包脚本检查宿主指定代码要求、ZIP 解压后的深度签名、钥匙串公钥与内置公钥一致性，
   并使用 CryptoKit 公钥验证档案签名。输出在 `local/releases/<version>-<build>/`，重复打包不覆盖已有产物。
4. 保留运行中的输入恢复机制，通过旧版本检查更新验证新包下载、安装、重启和辅助功能权限。
   对固定身份至少验收一次授权后连续两次更新。记录系统版本、各版本 CodeDirectory hash、指定代码要求及输入运行状态。
   不能把签名校验通过等同于真实权限验收通过。
5. 独立只读审查后，只暂存允许公开的源码和文档；提交、推送，创建标签和 Release。
   上传 ZIP、`appcast.xml`、`SHA256SUMS.txt`。先创建草稿并上传齐全部资产，再发布并设为 latest，避免 feed 短暂缺失。Release 说明必须保留“自签名、未公证”和最低系统版本。
6. 公开后下载资产校验哈希与签名，确认标签对应提交、CI 通过、旧应用能发现新版本。
   不覆盖已发布版本的 ZIP。修复另发更高版本。

固定 feed：`https://github.com/leon4z/MacTools/releases/latest/download/appcast.xml`。
feed 中的 ZIP 地址必须指向明确版本标签，不能指向 `latest`；否则缓存可能把旧签名与新包混用。
发布脚本同时签名 feed 和 ZIP。ZIP 的 Ed25519 签名是安装前的必要校验。

## 更新生命周期

默认关闭自动检查和自动下载/安装。用户可开启自动检查，最终安装仍确认。
Sparkle 的 `willInstallUpdate` 会暂停输入模块并恢复键鼠参数；正常退出同样执行恢复。
文件移动期间拒绝开始新更新检查；下载途中若新发起移动，重启会等待移动结束。
安装失败时恢复正常运行；临时暂停不会写入用户模块配置。

## 验证与恢复

```sh
codesign --verify --deep --strict build/MacTools.app
codesign -d -r- build/MacTools.app
```

使用 `scripts/verify-update.swift` 编译出的 CLI，可只凭内置公钥验证 ZIP，无需私钥或钥匙串访问。
CI 和开发构建显式使用 `MACTOOLS_SIGNING_IDENTITY=-`，不可作为正式更新包。
`install-local.sh` 默认固定证书，证书缺失时失败；安装前备份旧包，安装签名失败则恢复旧包。
旧备份保存在忽略的 `local/install-*/`。回退旧二进制不等于回退用户数据，先确认配置兼容。

Sparkle 文档：[发布](https://sparkle-project.org/documentation/publishing/)、
[程序化接入](https://sparkle-project.org/documentation/programmatic-setup/)。
