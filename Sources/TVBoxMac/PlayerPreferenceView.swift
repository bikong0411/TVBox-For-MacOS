import SwiftUI
import TVBoxCore

struct PlayerPreferenceView: View {
    @EnvironmentObject var store: AppStore
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(L10n.text("播放设置"), systemImage: "play.rectangle").font(.system(size: 17, weight: .semibold))
            HStack {
                Text(L10n.text("默认播放内核")).font(.system(size: 12)); Spacer()
                Picker(L10n.text("默认播放内核"), selection: $store.playbackPreference) {
                    ForEach(PlaybackPreference.allCases) { Text(L10n.string($0.title)).tag($0) }
                }.labelsHidden().frame(width: 300)
            }
            Text(MPVLibrary.componentURL != nil ? L10n.text("已检测到 IINA 的 mpv 组件。视频仍在 TVBox 内播放，支持选台、全屏和播放控制；组件不可用时自动回退 VLC。") : L10n.text("未找到 IINA 的 mpv 组件，将使用内置 VLC。安装 IINA 后，下次播放会重新检测。"))
                .font(.system(size: 11)).foregroundStyle(Theme.muted)
        }.padding(20).background(Theme.panel, in: RoundedRectangle(cornerRadius: 11))
    }
}
