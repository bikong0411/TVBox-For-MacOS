import Foundation

@main struct CheckLocalization {
    static func main() {
        let arguments = CommandLine.arguments
        let language = arguments[1]
        let english = language == "en"
        precondition(Bundle.main.preferredLocalizations.first == language)
        precondition(L10n.string("配置管理") == (english ? "Sources" : "配置管理"))
        precondition(L10n.string("播放菜单") == (english ? "Playback" : "播放"))
        precondition(L10n.string("优先 IINA 播放组件（软件内播放）") == (english ? "Prefer IINA component (inside TVBox)" : "优先 IINA 播放组件（软件内播放）"))
        let name = "源 %@ %d 100% / O'Neil"
        precondition(L10n.text("管理\(name)") == (english ? "Manage " : "管理") + name)
        precondition(L10n.text("\(3) 点播 · \(7) 直播") == (english ? "3 on-demand · 7 live" : "3 点播 · 7 直播"))
        precondition(L10n.string("来自订阅的未翻译名称") == "来自订阅的未翻译名称")
        precondition(L10n.channelGroup("体育赛事", automatic: true) == (english ? "Sports" : "体育赛事"))
        precondition(L10n.channelGroup("体育赛事", automatic: false) == "体育赛事")
        precondition(L10n.channelGroup("全部", automatic: false) == (english ? "All" : "全部"))
        precondition(L10n.text("未收录的提示 \(name)") == "未收录的提示 \(name)")
        precondition(L10n.isEnglish == english)
        let permission = Bundle.main.localizedInfoDictionary?["NSLocalNetworkUsageDescription"] as? String ?? ""
        precondition(permission.contains(english ? "Discover" : "发现"))
        print("PASS \(language): language selection, menus, enum labels, interpolation, literal content, fallback and permission text")
    }
}
