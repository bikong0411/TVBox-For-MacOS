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
            CommandGroup(replacing: .newItem) {
                Button("打开视频文件…") { store.openVideoFile() }.keyboardShortcut("o")
                Button("打开视频地址…") { store.directSheet = true }.keyboardShortcut("o", modifiers: [.command, .shift])
                Divider()
                Button("添加内容源…") { store.showImport() }.keyboardShortcut("i", modifiers: [.command, .shift])
                Button("导入配置文件…") { store.importFile() }
            }
            CommandMenu("播放") {
                Button("切换播放全屏") { store.fullscreen.toggle(store: store) }.keyboardShortcut("f", modifiers: [.command, .control]).disabled(store.playback == nil)
                Divider()
                Button("播放 / 暂停") { if store.player.player.rate == 0 { store.player.player.play() } else { store.player.player.pause() } }.keyboardShortcut(.space, modifiers: [])
                Button("下一集") { store.nextEpisode() }.keyboardShortcut(.rightArrow, modifiers: [.command])
                Button("使用 IINA 打开") { store.openIINA() }.disabled(store.playback == nil)
                Button("停止播放") { store.stop() }.keyboardShortcut(".")
            }
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) { NSApp.setActivationPolicy(.regular); NSApp.activate(ignoringOtherApps: true) }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}
