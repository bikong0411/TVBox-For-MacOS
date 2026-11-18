# TVBox for macOS

原生 SwiftUI 影视客户端，支持 **macOS 13+、Intel 和 Apple Silicon**。内置 VLC，可优先使用本机 IINA 的 mpv 组件，视频始终在 TVBox 内播放，无需额外安装播放器。

## 安装与使用

从 [Releases](https://github.com/bikong0411/TVBox-For-MacOS/releases) 下载对应芯片的安装包，解压后将 `TVBox.app` 放入“应用程序”。

1. 点击“添加内容源”，导入 TVBox JSON 配置或 M3U / TXT 直播列表。
2. 在“发现”选择点播源与接口，浏览、搜索并选择剧集；“电视直播”单独选择直播源。
3. 在“配置管理”中复制、修改或刷新源，调整播放器、语言和更新设置。

不附带公共影视源；未导入配置时提供 Blender 开放电影预告片演示。

## 主要功能

- **点播**：分类搜索、多线路选集、收藏、播放记录、断点续播和自动下一集。
- **直播**：列表 / 平铺、频道自动分组、透明选台栏；支持来源提供的节目单与回看。
- **播放**：本地文件与视频直链、全屏、倍速；左右方向键每次跳转 3 秒，支持连续调整。
- **投屏**：安卓电视 DLNA、Apple TV 及兼容电视 AirPlay。Mac 与电视需在同一局域网，播放能力取决于电视与片源。
- **网络探测**：批量检查接口和订阅，按响应耗时排序并推荐，源列表显示【123ms】。响应正常不代表视频一定可播。
- **中英文**：TVBox → 设置…，或配置管理 → 界面设置。支持跟随系统 / 简体中文 / English，手动选择优先于系统，点击“重启 TVBox…”后生效。
- **软件更新**：支持手动检查、自动检查和后台下载，正常退出时安装，并验证更新签名。

全屏可双击画面或按 `Control + Command + F`，按 `Esc` 返回。直播选台栏在鼠标移入时展开，移开无操作 3 秒后收起。

## 兼容范围

| 内容 | 支持情况 |
| --- | --- |
| TVBox JSON / JSON5、`sites` / `lives`、多仓目录 | 支持，点播源与直播源独立管理 |
| type 0 XML / type 1 JSON 接口 | 分类、搜索、详情与选集 |
| type 3 Java / CSP | 内置独立运行时，支持标准 Spider 与本地媒体代理 |
| M3U / TXT 直播 | 分组、台标、多线路、常见请求头 |
| HLS / MP4 / MKV / FLV / MPEG-TS | 由 mpv / VLC 播放，具体取决于编码与连接状态 |
| JS / Python 爬虫、type 4、加密配置、网页嗅探及解析服务 | 暂不支持 |

CSP 需要配置提供匹配的 `spider` / `jar`；旧配置请刷新一次。首次启动较慢，Intel 使用 ARM 模拟，等待可能更久。第三方专有运行库、登录流程及 DRM 内容不保证兼容。

播放结果若带 `qrcode` / `qrCode`（同名字段也可放在 `auth` 内），TVBox 可显示二维码供用户扫码后重试。支持二维码文本或内嵌 PNG / JPEG Data URL，也接受 `qr_image` 内嵌图片。片源需自行提供并维护授权流程。

## 本机构建

需要 Swift 6、Xcode Command Line Tools、Python 3.9+ 和 Homebrew。首次构建需联网下载固定校验的依赖与 CSP 运行时输入。

```bash
brew install e2fsprogs pkgconf
python3 scripts/prepare-csp-runtime.py
bash scripts/build-app.sh
```

默认按本机架构构建，输出 `dist/Release/TVBox.app` 和 `dist/TVBox-macOS-*.zip`。可显式指定 Intel 或通用版：

```bash
# Intel
python3 scripts/prepare-csp-runtime.py --arch x86_64
bash scripts/build-app.sh intel

# Intel + Apple Silicon 通用版
python3 scripts/prepare-csp-runtime.py --arch universal
bash scripts/build-app.sh --universal
```

运行测试：`bash scripts/test.sh`；语言检查：`python3 scripts/check-localization.py`。验证记录见 [VALIDATION.md](VALIDATION.md)。

## GitHub 自动编译与发布

将工程放在仓库根目录，确保 `Package.swift` 与 `.github` 同级。仅保留 [main.yml](.github/workflows/main.yml)，删除旧的 `macos-build.yml`。

- 推送 main / master、提交 PR，或在 **Actions → Build macOS → Run workflow** 手动触发编译。
- 完成后在该次运行的 **Artifacts** 下载 Intel / Apple Silicon 安装包，临时附件保留 14 天。
- 正式发布：先按 [更新发布说明](UPDATE-RELEASE.md) 配置 `SPARKLE_PRIVATE_KEY`，提交代码后推送新的 `vX.Y.Z` 标签。工作流自动设置安装包版本，构建两种架构并发布 Release，无需手动上传 ZIP。

工作流会先准备 CSP 运行时，再测试、编译和打包。修改流程后需新建运行或新标签，旧运行的 Re-run 仍使用旧提交。

## 数据与开源组件

配置、收藏和记录保存在本机用户偏好域 `local.tvboxmac`，不提供云同步。CSP 数据位于 `~/Library/Application Support/TVBoxMac/CSPRuntime/`。

第三方组件、许可证及源码见 [ThirdPartySources](ThirdPartySources/README.md)，CSP 的重建与对应源码见 [CSP-Runtime.md](ThirdPartySources/CSP-Runtime.md)。当前应用使用 ad hoc 签名，尚未进行 Apple Developer 分发签名与公证。
