#!/usr/bin/env python3
"""Collect generated source and release artifacts without caches or user data."""
from pathlib import Path
import shutil
import zipfile

root = Path(__file__).resolve().parent.parent
delivery = root.parent / "TVBoxMac-Delivery"
delivery.mkdir(exist_ok=True)
shutil.copytree(root / "dist/Release/TVBox.app", delivery / "TVBox.app", dirs_exist_ok=True)
shutil.copy2(root / "dist/TVBox-macOS-AppleSilicon.zip", delivery)
source = delivery / "Source"
source.mkdir(exist_ok=True)
for name in ["Package.swift", "README.md", "VALIDATION.md", ".gitignore", "Sources", "Tests", "Resources", "scripts", "Examples", "Helpers", "ThirdPartySources"]:
    path = root / name
    if path.is_dir():
        shutil.copytree(path, source / name, dirs_exist_ok=True, ignore=shutil.ignore_patterns("__pycache__", ".DS_Store"))
    else:
        shutil.copy2(path, source / name)
with zipfile.ZipFile(delivery / "TVBoxMac-Source.zip", "w", zipfile.ZIP_DEFLATED) as archive:
    for path in sorted(source.rglob("*")):
        if path.is_file():
            archive.write(path, Path("TVBoxMac") / path.relative_to(source))
(delivery / "使用说明.txt").write_text("""TVBox for macOS 0.6.4

直接打开 TVBox.app，可复制到“应用程序”后使用。
适用于 Apple Silicon（M 系列芯片），最低 macOS 13。

已支持：多个点播源与多个直播源独立保存和切换、JSON/XML 影视接口、分类搜索、多线路剧集、M3U/TXT 直播、视频直链、收藏和续播。
暂不支持：Android JAR/CSP、JS/Python 爬虫、type 4、加密配置、网页嗅探和解析服务。

点击“添加内容源”填入自己的 TVBox JSON 地址或选择本地文件。
可选择“仅点播源”或“仅直播源”，两份列表互不覆盖。
在“发现”页选择点播源与接口；在“电视直播”页单独选择直播源。
直播页右上方可以切换“列表 / 平铺”，展示偏好会在重启后保留。
频道默认按名称及原分组自动归入央视、卫视、影视、少儿、体育、新闻、纪录、音乐综艺、教育、生活、港澳台、国际、地方或其他类别；同组内按名称与频道数字排列，相近名称靠在一起。直播页和左侧选台栏均可切换分组、在组内搜索，也可切回“原始分组”，分类方式会记住。自动分类只影响展示，保留原有频道、线路、鉴权和节目单信息。
直播播放画面左侧显示“选台”窄条，鼠标移入即可展开透明频道栏，支持搜索和直接切台；鼠标留在栏内时保持展开，移开且无操作 3 秒后自动收起。
直播和点播都支持全屏：点击画面右下角“全屏”、双击视频画面，或按 Control + Command + F；Esc 或“退出全屏”返回播放窗口。播放菜单也有全屏入口。全屏保留播放进度、暂停和倍速，点播下一集继续全屏；全屏直播保留透明选台栏和回看返回入口。
点播与节目回看支持左方向键后退 3 秒、右方向键快进 3 秒，连续按或长按可连续调整，窗口和全屏均可使用；普通直播不跳转。若焦点在输入框、音量等控件上，可先点击视频画面再使用方向键。
播放控制条新增 AirPlay“投屏”图标，窗口和全屏均可使用。Mac 与兼容电视 / Apple TV 连接到同一网络，打开电视的 AirPlay 后，点击图标选择电视，按系统提示配对；在相同菜单选择此 Mac 可结束投屏。接收设备和片源需支持相应视频格式及访问方式。本机兼容直播的回环地址不能由电视直接访问，此类线路可改用 macOS 屏幕镜像。当前环境只验证设备菜单，电视端画面尚需连接实际设备验证。
来源提供节目单地址时，频道行右侧会显示节目单按钮，可切换日期查看节目预告；支持 TVBox 的 epg 模板及 M3U 的 x-tvg-url / url-tvg XMLTV。来源同时提供可识别的 catchup-source 回看模板时，已播出且在回看期限内的节目可点击播放，支持 default / append / shift，可随时返回直播。未提供节目单或回看信息的来源不会生成虚构内容；旧订阅需刷新配置或重新导入以读取新增元数据。
“网络探测”可批量检查配置中的点播接口、直播订阅及子配置 URL；支持设置超时和并发、停止、重测失败项、按结果筛选、按耗时排序及复制结果。不展开频道播放地址，HTTP 正常响应不代表视频一定能播放。
探测结束后默认按响应耗时从低到高排序，失败和未完成项排后。每类地址给出网络首选及最多两个备选，仅推荐 HTTP 2xx 正常响应及当前支持的点播接口；复制结果包含推荐标记。
配置管理会在对应直播订阅、子配置及点播接口后显示【123ms】；未探测不显示数值，失败显示【失败】，鼠标悬停可查看状态和耗时。
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
TVBox-macOS-AppleSilicon.zip 为应用压缩包。
测试结果见 Source/VALIDATION.md。

应用已做本机 ad hoc 签名，尚未做 Apple Developer 分发签名和公证。
""", encoding="utf-8")
print(delivery)
