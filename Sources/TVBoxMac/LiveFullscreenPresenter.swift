import SwiftUI
import AppKit

/// Hidden fixture windows can exercise the same lifecycle without entering a
/// real fullscreen Space or driving desktop input.
@MainActor struct FullscreenWindowActions {
    var present: (NSWindow) -> Void
    var enter: (NSWindow) -> Void
    var exit: (NSWindow) -> Void
    static var native: Self { Self(present: { $0.makeKeyAndOrderFront(nil) }, enter: { $0.toggleFullScreen(nil) }, exit: { $0.toggleFullScreen(nil) }) }
}

@MainActor final class PlaybackFullscreenPresenter: NSObject, ObservableObject, NSWindowDelegate {
    @Published private(set) var isPresented = false
    private(set) var window: NSWindow?
    private enum Phase { case windowed, entering, fullscreen, exiting }
    private var phase = Phase.windowed
    private var closeRequested = false
    private weak var returnWindow: NSWindow?
    private weak var store: AppStore?
    private let actions: FullscreenWindowActions
    init(actions: FullscreenWindowActions? = nil) { self.actions = actions ?? .native; super.init() }
    func toggle(store: AppStore) { if isPresented { close() } else { show(store: store) } }
    func show(store: AppStore) {
        guard store.playback != nil else { return }
        if let window { actions.present(window); return }
        self.store = store; returnWindow = NSApp.keyWindow
        let window = PlaybackFullscreenWindow(contentRect: returnWindow?.frame ?? NSRect(x: 0, y: 0, width: 1120, height: 680), styleMask: [.titled, .closable, .resizable, .miniaturizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.title = "TVBox · 播放"; window.titleVisibility = .hidden; window.titlebarAppearsTransparent = true
        window.backgroundColor = .black; window.collectionBehavior = [.fullScreenPrimary]; window.delegate = self
        window.onEscape = { [weak self] in self?.close() }
        self.window = window; closeRequested = false; phase = .entering
        store.player.videoSurface.setFullscreenHost(true)
        // Reuse AVPlayer, current item, clock, buffers and rate; the inline
        // player view detaches while fullscreen owns the video surface.
        isPresented = true
        window.contentView = NSHostingView(rootView: PlaybackFullscreenContent().environmentObject(store).preferredColorScheme(.dark))
        if returnWindow == nil { window.center() }
        actions.present(window); actions.enter(window)
    }
    func close() {
        guard let window else { return }; closeRequested = true
        switch phase {
        case .entering, .exiting: break
        case .fullscreen: phase = .exiting; actions.exit(window)
        case .windowed: finishClose()
        }
    }
    func closeImmediately() { finishClose(restore: false) }
    private func finishClose(restore: Bool = true, closeWindow: Bool = true) {
        let old = window; window = nil
        store?.player.videoSurface.setFullscreenHost(false)
        old?.delegate = nil; old?.contentView = nil; if closeWindow { old?.close() }
        phase = .windowed; closeRequested = false; isPresented = false
        if restore { returnWindow?.makeKeyAndOrderFront(nil) }
        returnWindow = nil; store = nil
    }
    private func owns(_ notification: Notification) -> Bool { (notification.object as? NSWindow) === window && window != nil }
    func windowWillEnterFullScreen(_ notification: Notification) { if owns(notification) { phase = .entering } }
    func windowDidEnterFullScreen(_ notification: Notification) {
        guard owns(notification) else { return }; phase = .fullscreen
        if closeRequested { close() }
    }
    func windowWillExitFullScreen(_ notification: Notification) { if owns(notification) { phase = .exiting } }
    func windowDidExitFullScreen(_ notification: Notification) { if owns(notification) { phase = .windowed; finishClose() } }
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard sender === window else { return true }
        if phase == .windowed { return true }; close(); return false
    }
    func windowWillClose(_ notification: Notification) { if owns(notification) { finishClose(closeWindow: false) } }
    func windowDidFailToEnterFullScreen(_ window: NSWindow) {
        guard window === self.window else { return }
        let store = store; finishClose(); store?.alert = "暂时无法进入全屏，请再试一次。"
    }
    func windowDidFailToExitFullScreen(_ window: NSWindow) {
        guard window === self.window else { return }; phase = .fullscreen; closeRequested = false
    }
}

private final class PlaybackFullscreenWindow: NSWindow {
    var onEscape: (() -> Void)?
    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown, event.keyCode == 53 { onEscape?(); return }
        super.sendEvent(event)
    }
}

struct PlaybackFullscreenContent: View {
    @EnvironmentObject var store: AppStore
    var body: some View {
        PlaybackSurface(controller: store.player, fullscreen: store.fullscreen, isFullscreen: true)
            .overlay(alignment: .topTrailing) {
                if store.playback?.catchupProgramme != nil, let channel = store.playingChannel {
                    Button { store.playChannel(channel) } label: {
                        Label("返回直播", systemImage: "dot.radiowaves.left.and.right").font(.system(size: 12)).padding(10).background(.black.opacity(0.3), in: RoundedRectangle(cornerRadius: 7))
                    }.buttonStyle(.plain).foregroundStyle(Theme.accent).padding(16)
                }
            }
            .background(.black).ignoresSafeArea().onExitCommand { store.fullscreen.close() }
    }
}
