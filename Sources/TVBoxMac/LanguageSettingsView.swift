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
    @State private var confirmQuit = false
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
                    Text(L10n.text("已保存，重新打开 TVBox 后生效。"))
                        .font(.system(size: 12)).foregroundStyle(Theme.accent)
                    Spacer()
                    Button(L10n.text("退出 TVBox…")) { confirmQuit = true }
                }
            }
        }.padding(20).background(Theme.panel, in: RoundedRectangle(cornerRadius: 11))
        .confirmationDialog(L10n.text("退出 TVBox 以应用语言设置？"), isPresented: $confirmQuit, titleVisibility: .visible) {
            Button(L10n.text("退出 TVBox")) { NSApp.terminate(nil) }
            Button(L10n.text("稍后"), role: .cancel) { }
        } message: {
            Text(L10n.text("播放进度会保存。退出后重新打开 TVBox，即可使用所选语言。"))
        }
    }
}
