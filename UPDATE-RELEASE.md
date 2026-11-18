# 自动更新发布说明

更新仓库：[bikong0411/TVBox-For-MacOS](https://github.com/bikong0411/TVBox-For-MacOS)。

应用的 TVBox 菜单和“配置管理 → 软件更新”都可以检查正式版。默认每天检测、后台下载，正常退出时安装；也可在更新准备好后明确选择“安装并重启”。安装会保存进度并关闭播放器和内置 CSP 运行时。Intel 与 Apple Silicon 分别使用对应更新清单，安装前验证清单和 ZIP 的签名。

## 第一次发布，只需配置一次

1. 将本次 `Source/` 里的完整工程文件上传到仓库根目录，包含隐藏的 `.github` 目录。`Package.swift` 与 `.github` 必须同级。不要将 `.app` 或源码 ZIP 当作工程上传。`TVBoxMac-GitHub-Source.zip` 是去掉大依赖归档后的工程，可解压后使用；依赖由 Actions 下载并验证。
2. 工作流位于 `.github/workflows/macos-build.yml`。如果仓库中已有同用途的 `main.yml`，请用新工作流内容覆盖原文件，或替换成此文件；同一份构建流程只保留一个工作流，避免重复发布。
3. 更新专用签名已配置，公钥位于 `Resources/Info.plist` 的 `SUPublicEDKey`。私钥保存在本机登录钥匙串，账户名为 `bikong0411.TVBox-For-MacOS`，并备份到：

   `~/Library/Application Support/TVBoxMac/UpdateSigning/bikong0411.TVBox-For-MacOS/SPARKLE_PRIVATE_KEY.txt`

4. 打开 [仓库 Actions Secrets](https://github.com/bikong0411/TVBox-For-MacOS/settings/secrets/actions)，选择 **New repository secret**。名称填写 `SPARKLE_PRIVATE_KEY`，值填写上述文件的完整内容。私钥不放入仓库、源码 ZIP 或应用。
5. 提交更新后的源码及工作流，再发布指向该提交的正式标签，例如 `v0.9.6`。Actions 会编译两种架构，验证安装包，签名并生成更新清单，然后发布 Release。

0.9.3 及更早版本没有应用内更新功能，需要手动安装一次 0.9.4 或更新版本；之后才能自动更新。

## 后续发布

提交代码后推送新的 `vX.Y.Z` 标签即可。无需手动上传 ZIP，也无需重新生成密钥。工作流自动产出：

- `TVBox-macOS-Intel.zip` 与 SHA-256；
- `TVBox-macOS-AppleSilicon.zip` 与 SHA-256；
- `appcast-Intel.xml` 与 `appcast-AppleSilicon.xml`，包含更新包及清单签名；
- CSP 运行时对应源码包。

应用使用 `https://github.com/bikong0411/TVBox-For-MacOS/releases/latest/download/appcast-Intel.xml` 或 `appcast-AppleSilicon.xml`。版本来源是正式 Release，不读取保留 14 天的 Actions 临时附件。

普通分支 / PR 构建不发布更新，也不需要私钥。正式标签缺少签名 Secret、两种架构版本不一致、公钥不匹配或校验失败时，发布任务会失败，不生成未签名的更新。新的 Release 先作为草稿上传完整附件，完成后才公开。

## 本机发布与恢复密钥

`python3 scripts/setup-update-signing.py` 可再次显示配置和备份路径。该脚本保留已存在的专用密钥，不会替换已发布的公钥。

换电脑时，需要把原私钥导入同一钥匙串账户，再运行设置脚本：

```sh
python3 scripts/prepare-sparkle.py
Vendor/SparkleDistribution/bin/generate_keys --account bikong0411.TVBox-For-MacOS -f /安全位置/SPARKLE_PRIVATE_KEY.txt
python3 scripts/setup-update-signing.py
```

现有安装只信任已经嵌入的公钥；后续发布继续使用同一私钥。Apple Developer 签名 / 公证仍与更新签名独立，当前工程保持已有 ad hoc 签名方式。

## 验证

`scripts/check-app-update.py` 使用独立应用标识、独立偏好与临时签名测试包，验证真实 Sparkle 更新，不改动正式 TVBox。可选择 `manual`、`automatic`、`ready-install`、`no-update`、`tampered-feed`、`tampered-archive`；手动及立即安装模式需点击测试更新窗口的安装及重启按钮。

框架与签名机制参考 [Sparkle 官方文档](https://sparkle-project.org/documentation/)。
