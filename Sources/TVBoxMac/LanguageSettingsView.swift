import SwiftUI
import AppKit

@MainActor final class LanguageSettings: ObservableObject {
    static let shared = LanguageSettings()
    @Published private(set) var selection: InterfaceLanguage
    private let defaults: UserDefaults
    let applied: InterfaceLanguage
    init(defaults: UserDefaults = LanguagePreferences.store) {
        self.defaults = defaults
        applied = L10n.appliedLanguage
        selection = LanguagePreferences.selection(in: defaults)
    }
    var needsReopen: Bool { selection != applied }
    func select(_ value: InterfaceLanguage) {
        guard selection != value else { return }
        LanguagePreferences.save(value, in: defaults)
        selection = value
    }
}

struct LanguageSettingsView: View {
    @ObservedObject private var settings = LanguageSettings.shared
    @ObservedObject var updates: AppUpdateController
    @State private var confirmRestart = false
    @State private var restartFailed = false
    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            Label(L10n.text("界面设置"), systemImage: "globe").font(.system(size: 17, weight: .semibold))
            HStack {
                Text(L10n.text("界面语言")).font(.system(size: 12))
                Spacer()
                Picker(L10n.text("界面语言"), selection: Binding(get: { settings.selection }, set: settings.select)) {
                    ForEach(InterfaceLanguage.allCases) { Text($0.title).tag($0) }
                }.pickerStyle(.segmented).labelsHidden().frame(width: 350)
            }
            Text(L10n.text("手动选择的语言优先于 macOS 设置；选择“跟随系统”时使用 macOS 的应用语言。"))
                .font(.system(size: 11)).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
            if settings.needsReopen {
                HStack(spacing: 12) {
                    Text(L10n.text("已保存，重启 TVBox 后生效。"))
                        .font(.system(size: 12)).foregroundStyle(Theme.accent)
                    Spacer()
                    Button(L10n.text("重启 TVBox…")) { confirmRestart = true }
                }
            }
        }.padding(20).background(Theme.panel, in: RoundedRectangle(cornerRadius: 11))
        .confirmationDialog(L10n.text("重启 TVBox 以应用语言设置？"), isPresented: $confirmRestart, titleVisibility: .visible) {
            Button(L10n.text("重启 TVBox")) { restart() }
            Button(L10n.text("稍后"), role: .cancel) { }
        } message: {
            Text(updates.readyOnQuit
                 ? L10n.text("播放进度会保存，已下载的更新会在重启时安装。")
                 : L10n.text("播放进度会保存。重启后将使用所选语言。"))
        }
        .alert(L10n.text("无法自动重启 TVBox"), isPresented: $restartFailed) {
            Button(L10n.text("知道了"), role: .cancel) { }
        } message: {
            Text(L10n.text("语言设置已保存，请退出并重新打开 TVBox。"))
        }
    }

    private func restart() {
        if updates.readyOnQuit {
            updates.installPreparedUpdate()
            return
        }
        do {
            try AppRelaunch.schedule()
            NSApp.terminate(nil)
        } catch {
            restartFailed = true
        }
    }
}

private enum AppRelaunch {
    static func schedule() throws {
        let app = Bundle.main.bundleURL
        guard app.pathExtension.lowercased() == "app" else { throw CocoaError(.executableNotLoadable) }
        let info = ProcessInfo.processInfo
        let helper = Process()
        helper.executableURL = URL(fileURLWithPath: "/bin/sh")
        // Wait for normal termination, including playback and preference cleanup.
        helper.arguments = ["-c", """
            pid=$1
            app=$2
            shift 2
            for i in $(/usr/bin/seq 120); do
                if ! kill -0 "$pid" 2>/dev/null; then
                    exec /usr/bin/open -a "$app" "$@"
                fi
                /bin/sleep 0.25
            done
            """, "tvbox-relaunch", String(info.processIdentifier), app.path]
        if info.arguments.contains("--ui-test") {
            helper.arguments?.append(contentsOf: ["--args"] + info.arguments.dropFirst())
        }
        try helper.run()
    }
}
