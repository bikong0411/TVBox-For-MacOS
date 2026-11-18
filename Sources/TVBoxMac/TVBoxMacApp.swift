import SwiftUI
import AppKit

@main struct TVBoxMacApp: App {
    @StateObject private var store = AppStore()
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    var body: some Scene {
        WindowGroup {
            ContentView().environmentObject(store).preferredColorScheme(.dark)
                .frame(minWidth: 960, minHeight: 660)
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in store.shutdown() }
                .onOpenURL { url in
                    if ["json", "m3u", "m3u8", "txt"].contains(url.pathExtension.lowercased()) { Task { await store.importURL(url.absoluteString) } }
                    else { _ = store.playDirect(url.absoluteString) }
                }
        }
        .defaultSize(width: 1240, height: 820)
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(after: .appInfo) { CheckForAppUpdatesMenu(updates: store.updates) }
            CommandGroup(replacing: .newItem) {
                Button(L10n.text("打开视频文件…")) { store.openVideoFile() }.keyboardShortcut("o")
                Button(L10n.text("打开视频地址…")) { store.directSheet = true }.keyboardShortcut("o", modifiers: [.command, .shift])
                Divider()
                Button(L10n.text("添加内容源…")) { store.showImport() }.keyboardShortcut("i", modifiers: [.command, .shift])
                Button(L10n.text("导入配置文件…")) { store.importFile() }
            }
            CommandMenu(L10n.text("播放菜单")) {
                Button(L10n.text("切换播放全屏")) { store.fullscreen.toggle(store: store) }.keyboardShortcut("f", modifiers: [.command, .control]).disabled(store.playback == nil)
                Divider()
                Button(L10n.text("播放 / 暂停")) { store.player.togglePlayback() }.keyboardShortcut(.space, modifiers: []).disabled(store.playback == nil)
                Button(L10n.text("下一集")) { store.nextEpisode() }.keyboardShortcut(.rightArrow, modifiers: [.command])
                Button(L10n.text("停止播放")) { store.stop() }.keyboardShortcut(".")
            }
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) { NSApp.setActivationPolicy(.regular); NSApp.activate(ignoringOtherApps: true) }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}
