# TVBox for tvOS

面向 **tvOS 17.0+** 的电视端。支持独立导入用户提供的 TVBox JSON 配置、type 0 XML / type 1 JSON 点播和 M3U / TXT 直播列表。遥控器可浏览片库、选集、播放直播、聚合搜索和换源，播放记录保存在 Apple TV 本机。

使用标准 HLS 和兼容编码的 MP4。网络来源优先使用 HTTPS。片源要求 Android JAR / CSP、额外媒体请求头或 Mac 专属播放器时，请使用对应的兼容来源。

## 安装到自己的 Apple TV

1. 在完整 Xcode 中安装 tvOS 平台支持，打开 [TVBoxTV.xcodeproj](TVBoxTV.xcodeproj)。
2. 选择 `TVBoxTV` scheme。可以先在 Apple TV 模拟器运行，进入「片库」播放演示视频。
3. 用 Xcode 的 Device Hub 配对 Apple TV。选择 `TVBoxTV` target 的 **Signing & Capabilities**，设置自己的 Team 和唯一 Bundle Identifier。
4. 选中 Apple TV 真机作为运行设备，使用 **Product → Run** 安装并启动。进入「片源」输入订阅地址，然后在「片库」或「直播」播放。

## 验证构建

通过 GitHub Actions 的 **Build tvOS** 检查模拟器和真机的无签名编译。该检查无需准备 Mac 版的 VLC、Sparkle 或 CSP 组件。它生成的无签名构建用于验证编译。真机安装需要自己的 Xcode 开发签名。

```bash
xcodebuild -project TVBoxTV/TVBoxTV.xcodeproj -scheme TVBoxTV \
  -destination 'generic/platform=tvOS Simulator' CODE_SIGNING_ALLOWED=NO build
```
