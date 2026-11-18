# CSP 独立运行时

运行时只在使用 Java / CSP 接口时启动，视频继续由 TVBox 的 mpv / VLC 播放。
不要求用户安装 Java、Android SDK、Docker、模拟器或连接 Android 设备。
Apple Silicon 使用 HVF；Intel 使用 QEMU TCG 执行相同的 ARM64 组件。
Intel 使用双核多线程模拟；首次启动和复杂组件初始化可能需要数分钟。x86_64 运行时已通过 Rosetta 验证，未在物理 Intel Mac 上新增实测。
系统镜像不包含测试用影视配置、第三方爬虫组件、账号或用户的订阅信息。
构建时只初始化系统框架与自带 Worker，再清除 Worker 数据、近期任务和系统生成的设备标识，作为首次启动缓存。

## 固定输入与来源

完整下载地址、文件大小与 SHA-256 见 `scripts/csp/downloads.json`。

| 组件 | 版本 / 来源 | 许可证与源码 |
| --- | --- | --- |
| QEMU | 10.2.4，未经修改的上游源码 | GPL-2.0 / LGPL-2.1，运行时 `licenses/` 与对应源码包 |
| GLib | 2.88.4，依赖源码固定在同一源码档案内 | LGPL-2.1；动态库独立放置于各架构的 `lib/` |
| Linux | Debian 6.1.192-2，ARM64 | GPL-2.0；Debian 原始源码及补丁在对应源码包 |
| BusyBox | Debian 1.35.0-4+deb12u1 | GPL-2.0；原始源码及补丁在对应源码包 |
| glibc | Debian 2.36-9+deb12u14，随静态 BusyBox | LGPL-2.1；原始源码及补丁在对应源码包 |
| Android / ReDroid | Android 13 64-only，镜像层 SHA-256 固定 | 镜像附带 `Android-NOTICE.xml.gz`；[ReDroid 源码构建说明](https://github.com/remote-android/redroid-doc#how-to-build)、[源码清单](https://github.com/remote-android/local_manifests)、[Android 平台源码](https://android.googlesource.com/platform/manifest/) |
| gvproxy | 0.9.0 | [Apache-2.0 及依赖声明 / 对应版本源码](https://github.com/containers/gvisor-tap-vsock/tree/v0.9.0) |
| Worker Java 运行库 | OkHttp、Okio、Kotlin、Gson、jsoup 等 | 固定版本、来源与 SHA-256 见 `Helpers/CSPWorker/dependencies.json`；可用的许可证原文保存在 Worker APK 的 `assets/licenses/` |

JRE、Android SDK、ECJ、Meson、Ninja 和 e2fsprogs 只用于构建，不随应用运行。
QEMU 源码档案取自 Arcbox 的对应源码发布，其中包含 QEMU、GLib、libffi、PCRE2、proxy-libintl 和 dtc。
构建使用上游源码；不应用档案内附带的第三方 QEMU 补丁。

## 从源码重建

在 macOS 上安装 Xcode / Command Line Tools、Python 3.9+ 与构建依赖：

```sh
brew install e2fsprogs pkgconf
python3 scripts/prepare-csp-runtime.py --arch universal
bash scripts/build-app.sh --universal
python3 scripts/csp/package-sources.py
```

单独构建 Intel 时将 `--arch universal` 改为 `--arch x86_64`，应用构建参数改为 `intel`。
下载和构建缓存位于 `.build/csp-runtime`，输出位于 `Vendor/CSPRuntime`。
GitHub Actions 对每种原生 Mac 架构执行同样的流程，并附带对应源码包。

`Helpers/CSPRuntimeHost.swift` 管理 QEMU 和私有网络辅助进程，通过匿名管道跟随 TVBox 生命周期。
正常退出、父进程崩溃导致的管道关闭，以及辅助进程收到 SIGTERM / SIGINT，都会触发有时限的关机与进程清理。
不为 Android 暴露共享文件夹；只转发带随机 Bearer 令牌的本机 Worker HTTP 端口。
生产运行不输出源地址、插件异常内容或令牌日志。`--diagnostics` 仅用于开发测试，日志文件权限为 0600。

`Helpers/CSPWorker/worker-development.p12` 是专供私有 Android 镜像使用的开发签名，口令为 `tvbox-worker-development`。
它不代表 Apple Developer 或用户身份；保留这个签名可以避免更新应用时改变 Worker 的 Android 签名身份。

持久数据位于 `~/Library/Application Support/TVBoxMac/CSPRuntime/data-v1.qcow2`。
这是运行库与源组件的数据镜像，不是视频文件缓存。临时系统写入层随运行时退出删除。

## 能力边界

支持标准 Spider 的初始化、首页、分类、搜索、详情与直链播放解析；保留原始播放 ID 和返回的 HTTP 请求头。
组件校验失败、缺少运行库、调用超时或需要网页解析时返回中文说明。
JS / Python 爬虫、网页嗅探、`parses` 服务和专有 SDK 不属于这套 Java Worker 的支持范围。
标准 `Proxy.proxy(Map)` / `proxyLocal(Map)` 回调可通过认证的 Worker 媒体端点流式转发，支持 HLS、分段和 Range。Mac 为每次播放提供临时回环地址，停止、换片或退出关闭服务；不会直接剥离插件的代理 URL 或把整个视频写入缓存。其他私有安卓代理服务、网页解析和专有 SDK 仍可能不兼容。
需要登录的源仍需来源提供正常的授权方式，运行时不会绕过账号、付费或设备授权。
