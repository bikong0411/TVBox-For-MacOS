#!/usr/bin/env python3
"""Collect generated source and release artifacts without caches or user data."""
from pathlib import Path
import shutil
import zipfile

root = Path(__file__).resolve().parent.parent
delivery = root.parent / "TVBoxMac-Delivery"
delivery.mkdir(exist_ok=True)
if (delivery / "TVBox.app").exists(): shutil.rmtree(delivery / "TVBox.app")
shutil.copytree(root / "dist/Release/TVBox.app", delivery / "TVBox.app", symlinks=True)
for name in ["TVBox-macOS-Universal.zip", "TVBox-macOS-Intel.zip", "TVBox-macOS-AppleSilicon.zip", "TVBox-CSP-Corresponding-Sources.zip"]:
    shutil.copy2(root / "dist" / name, delivery)
source = delivery / "Source"
if source.exists(): shutil.rmtree(source)
source.mkdir(exist_ok=True)
for name in ["Package.swift", "README.md", "VALIDATION.md", "UPDATE-RELEASE.md", ".gitignore", ".github", "Sources", "Tests", "Resources", "scripts", "Examples", "Helpers", "ThirdPartySources"]:
    path = root / name
    if name == "Sources":
        # Only SwiftPM's declared source modules belong in the distribution. Preserve
        # unrelated workspace copies without recursively packaging them.
        for module in ["TVBoxCore", "TVBoxMac", "MPVBridge"]:
            shutil.copytree(path / module, source / name / module, dirs_exist_ok=True)
        continue
    if path.is_dir():
        shutil.copytree(path, source / name, dirs_exist_ok=True, ignore=shutil.ignore_patterns("__pycache__", ".DS_Store"))
    else:
        shutil.copy2(path, source / name)
with zipfile.ZipFile(delivery / "TVBoxMac-Source.zip", "w", zipfile.ZIP_DEFLATED) as archive:
    for path in sorted(source.rglob("*")):
        if path.is_file():
            archive.write(path, Path("TVBoxMac") / path.relative_to(source))
with zipfile.ZipFile(delivery / "TVBoxMac-GitHub-Source.zip", "w", zipfile.ZIP_DEFLATED) as archive:
    for path in sorted(source.rglob("*")):
        if not path.is_file(): continue
        relative = path.relative_to(source)
        if relative.parts[0] == "ThirdPartySources" and path.suffix in [".zip", ".xz", ".gz"]: continue
        if path.name.startswith("SPARKLE_PRIVATE_KEY"): continue
        archive.write(path, relative)
for name in ["appcast-Intel.xml", "appcast-AppleSilicon.xml", "TVBox-macOS-Intel.sha256", "TVBox-macOS-AppleSilicon.sha256"]:
    if (root / "dist" / name).exists(): shutil.copy2(root / "dist" / name, delivery / name)
(delivery / "使用说明.txt").write_text("""TVBox for macOS 0.9.6

直接打开 TVBox.app，可复制到“应用程序”后使用。
适用于 Intel（x86_64）与 Apple Silicon（M 系列芯片），最低 macOS 13。
默认优先复用本机 IINA 的 libmpv 播放组件，视频在 TVBox 内显示，不打开 IINA 窗口。组件未安装或不兼容时，自动回退随软件自带的 VLC；不强制安装其他播放器。配置管理 → 播放设置可选择“始终使用内置 VLC”。
mpv 和 VLC 均支持 TVBox 内的进度、暂停、倍速、全屏、选台、记录与续播。IINA 的个人设置和播放记录不会被读取或改写。
mpv 点播连接失败时自动尝试一次 macOS 网络兼容连接，保留进度和播放状态，仍由 mpv 在软件内播放；支持 HLS 分段、重定向和片源请求头。停止或换集关闭临时服务，不生成磁盘视频缓存，不关闭 HTTPS 证书校验。
mpv 库加载与内核初始化改为后台执行，减少点击播放时的界面停顿。点播兼容连接成功后，同源且请求头相同的下一集优先复用该方式；记忆只在本次运行保留，15 分钟过期，最多 64 项，失效会清除并回退直连。直播及本地文件保留原路径，连接失败重试仍有次数限制。
AirPlay 选中设备后主动发起视频播放，只有系统播放器就绪、定位完成且播放进度推进后才显示“投屏中”；加载、定位和电视响应均有超时，失败继续本机播放。系统 AirPlay 使用系统播放通道，部分 mpv / VLC 能播的片源仍可能无法直投，此时可尝试“安卓电视 · DLNA”。
小米等兼容接收器可选择“投屏 → AirPlay 电视 → 兼容连接”中的电视，直接进行 AirPlay 视频投放。该方式不依赖系统播放器加载片源，客厅小米电视已验证出画及暂停、跳转、继续、停止和返回本机；上方系统 AirPlay 入口继续保留。兼容连接支持 HTTP / HTTPS、本地视频及 HLS 转发，支持切集重投和返回本机，电视音量请使用遥控器调整；结束时关闭临时转发服务，无磁盘视频缓存。需要密码或配对的设备请使用系统 AirPlay 完成授权，软件不会绕过授权。

已支持：多个点播源与多个直播源独立保存和切换、JSON/XML 影视接口、分类搜索、多线路剧集、M3U/TXT 直播、视频直链、收藏和续播。
0.9.6 修复原始订阅更新 JAR 后旧校验值导致的重复失败。发现页遇到组件校验不匹配时，仅刷新当前原订阅一次，再按新声明重新校验；成功后保存该订阅。持续不匹配、本机修正组件失败或接口已更换时停止并说明，不跳过校验，也不套用其他仓库的组件。
0.9.5 的顶部菜单、侧边栏、播放 / 投屏操作、配置管理及网络探测支持简体中文和英文，跟随 macOS 为应用选择的语言，重新打开应用后生效。可在 macOS“系统设置 → 通用 → 语言与地区 → 应用程序”中单独为 TVBox 选择语言。英文长标签已调整布局。
新增 Java / CSP（type 3）支持：Mac 内置独立运行时，运行不要求 Java、Android SDK、Docker 或其他设备。支持标准 Spider 初始化、首页、分类、搜索、详情和直链播放解析。旧版保存的配置请在配置管理刷新一次，读取 spider / jar 和 ext 后重新选择接口。视频继续在软件内的 mpv / VLC 播放。
0.9.4 增加软件更新：TVBox 菜单或配置管理中可检查新版本，默认每天检查并后台下载，退出时安装。更新来自 GitHub 正式 Release，按 Intel / Apple Silicon 匹配，并验证签名。首次发布的配置步骤见 Source/UPDATE-RELEASE.md。
0.9.3 增加 Java / CSP 标准本地视频代理回调及流式转发，支持常见 Proxy.proxy / proxyLocal、HLS 清单、分段和 Range。代理按播放会话创建，停止、切集或退出关闭，不将整个视频写入磁盘。接口返回空播放结果会给出明确说明；此能力不等于网页嗅探、转码或专有云盘 SDK 支持。
0.9.2 支持 urls 及 storeHouse / sourceName / sourceUrl 多仓目录。在“发现”中选择原始仓库后，按原仓库地址加载自己的 spider / jar，保留仓库独立身份，不再将所有接口套用聚合器的同一个全局组件。可搜索仓库和打开嵌套目录，直播清单自动加入直播源。已经丢失原始归属的扁平合并配置无法可靠自动还原，请导入来源提供的多仓版或原仓库。
0.9.1 补齐标准 Spider.safeDns 接口，区分“爬虫入口不存在”“依赖库缺失”和“运行时接口版本不兼容”。针对单个接口的本机组件修正会跨刷新和重启保留；配置管理显示“本机修正组件”，右键可恢复源配置提供的组件。修正只对同一订阅、接口 key 与 API 生效，修改订阅地址后清除。
运行时按需启动，Apple Silicon 使用硬件加速；Intel 使用 ARM 模拟，首次启动可能需要数分钟。退出 TVBox 后自动关闭运行时。数据位于 ~/Library/Application Support/TVBoxMac/CSPRuntime/data-v1.qcow2，这是组件数据镜像，不是视频缓存。
暂不支持：JS/Python 爬虫、type 4、加密配置、网页嗅探和解析服务。不能保证所有第三方 CSP、专有 SDK 或登录流程可用；需要正常账号授权的来源仍按其规则使用。

点击“添加内容源”填入自己的 TVBox JSON 地址或选择本地文件。
可选择“仅点播源”或“仅直播源”，两份列表互不覆盖。
在“发现”页选择点播源与接口；在“电视直播”页单独选择直播源。
直播页右上方可以切换“列表 / 平铺”，展示偏好会在重启后保留。
频道默认按名称及原分组自动归入央视、卫视、影视、少儿、体育、新闻、纪录、音乐综艺、教育、生活、港澳台、国际、地方或其他类别；同组内按名称与频道数字排列，相近名称靠在一起。直播页和左侧选台栏均可切换分组、在组内搜索，也可切回“原始分组”，分类方式会记住。自动分类只影响展示，保留原有频道、线路、鉴权和节目单信息。
直播播放画面左侧显示“选台”窄条，鼠标移入即可展开透明频道栏，支持搜索和直接切台；鼠标留在栏内时保持展开，移开且无操作 3 秒后自动收起。
直播和点播都支持全屏：点击画面右下角“全屏”、双击视频画面，或按 Control + Command + F；Esc 或“退出全屏”返回播放窗口。播放菜单也有全屏入口。全屏保留播放进度、暂停和倍速，点播下一集继续全屏；全屏直播保留透明选台栏和回看返回入口。
点播与节目回看支持左方向键后退 3 秒、右方向键快进 3 秒，连续按或长按可连续调整，窗口和全屏均可使用；普通直播不跳转。若焦点在输入框、音量等控件上，可先点击视频画面再使用方向键。
mpv 组件与 VLC 均可解码 FLV、MKV、MPEG-TS 等格式。mpv 直接接收片源全部请求头（含 Cookie、Authorization）；VLC 保留 UA / Referer，其他自定义头仍走系统兼容通道。
点击“投屏”、搜索设备及切换 DLNA / AirPlay 标签不重新加载当前线路。打开系统 AirPlay 设备菜单时只准备暂停的候选系统播放器，当前视频保持原内核、原进度播放；实际连接设备后才切换通道，取消准备保留当前播放。系统不支持该片源时给出说明，可继续本机观看。
播放控制条“投屏”支持安卓电视 DLNA 和 Apple TV AirPlay，窗口和全屏均可使用。国产安卓电视：开启 DLNA / 多屏互动，在“安卓电视 · DLNA”中搜索并选择电视。电视确认播放后暂停本机，可按电视能力控制暂停、进度、音量与静音；返回本机保留点播进度。Mac 会临时转发视频、本地文件及 HLS，投屏期间请保持 Mac 在线；结束后关闭服务，不生成磁盘视频缓存。MP4 / HLS 兼容性较好，编码仍需电视支持，不提供转码或 Google Cast。Apple TV：点击“Apple TV · AirPlay”中的系统图标选择设备并配对，选择“此 Mac”结束；系统通道支持的访问方式由系统与电视决定。当前通过本机模拟电视验证 DLNA 协议和读取，实际电视配对、出画与具体格式仍需实机确认。
来源提供节目单地址时，频道行右侧会显示节目单按钮，可切换日期查看节目预告；支持 TVBox 的 epg 模板及 M3U 的 x-tvg-url / url-tvg XMLTV。来源同时提供可识别的 catchup-source 回看模板时，已播出且在回看期限内的节目可点击播放，支持 default / append / shift，可随时返回直播。未提供节目单或回看信息的来源不会生成虚构内容；旧订阅需刷新配置或重新导入以读取新增元数据。
“网络探测”可批量检查配置中的点播接口、直播订阅及子配置 URL；支持设置超时和并发、停止、重测失败项、按结果筛选、按耗时排序及复制结果。不展开频道播放地址，HTTP 正常响应不代表视频一定能播放。
探测结束后默认按响应耗时从低到高排序，失败和未完成项排后。每类地址给出网络首选及最多两个备选，仅推荐 HTTP 2xx 正常响应及当前支持的点播接口；复制结果包含推荐标记。
配置管理会在对应直播订阅、子配置及点播接口后显示【123ms】；未探测不显示数值，失败显示【失败】，鼠标悬停可查看状态和耗时。
配置管理的点播源和直播源均可复制完整源地址，或在行末菜单选择“修改名称 / 地址”。仅改名无需联网；修改 URL 先验证再替换，失败或取消保留原源，不改变其他源与选择。
配置管理的直播源列表可选择“时延从低到高”或“原始顺序”，默认按时延排序并记住偏好；直播页的源选择器同步排序，正常项显示【123ms】，不会改变当前所选源。
同组同名且请求头相同的频道合并为多条线路，播放页可直接上一台 / 下一台；返回列表保留搜索、分组及当前频道位置。
源选择使用轻量状态保存，配置后台写入；近期直播列表使用内存缓存，手动刷新可重新取回。
直播线路失败会自动依次尝试同频道备用地址，每条不同地址仅尝试一次；本次运行记住成功线路。全部失败时给出中文提示，可刷新列表或更换直播源。
视频和配置 / 接口请求遇到 TLS 连接失败时会自动重试一次，仍失败显示中文说明；直播每条线路重试失败后继续尝试备用线路。停止播放或切换视频会取消旧的重试，点播重连保留进度和暂停状态。
旧版正式配置自动迁移，收藏与播放记录保留。
正式版与开发测试窗口的配置数据独立，正式版首次打开需重新导入配置。
没有内置公共影视采集源；默认提供一部 Blender 官方预告片作演示。

Source/ 是完整源码工程，开发和构建说明见 Source/README.md。
TVBoxMac-Source.zip 为源码压缩包。
TVBox-CSP-Corresponding-Sources.zip 为 CSP 运行时相关开源组件的对应源码及构建说明。
TVBox-macOS-Universal.zip 为 Intel / Apple Silicon 通用应用。
TVBox-macOS-Intel.zip 为仅 Intel 的应用压缩包。
在 Intel Mac 编译：安装 Swift 6 / Command Line Tools、Python 3.9+、e2fsprogs 和 pkgconf，进入 Source 先执行 python3 scripts/prepare-csp-runtime.py，再执行 bash scripts/build-app.sh intel。首次需联网下载固定校验的构建输入，详细步骤见 Source/README.md。
测试结果见 Source/VALIDATION.md。

应用已做本机 ad hoc 签名，尚未做 Apple Developer 分发签名和公证。
""", encoding="utf-8")
print(delivery)
