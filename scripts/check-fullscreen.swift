import AppKit
import SwiftUI
import AVKit
import TVBoxCore

@MainActor final class FullscreenFixtureDriver {
    var enters = 0, exits = 0, everVisible = false
    var actions: FullscreenWindowActions {
        FullscreenWindowActions(present: { [unowned self] in self.everVisible = self.everVisible || $0.isVisible },
            enter: { [unowned self] in self.enters += 1; self.everVisible = self.everVisible || $0.isVisible },
            exit: { [unowned self] in self.exits += 1; self.everVisible = self.everVisible || $0.isVisible })
    }
}

@MainActor enum FullscreenChecks {
    private static func require(_ value: @autoclosure () -> Bool, _ message: String) throws { try CheckLiveOverlay.require(value(), message) }
    private static func boundPlayers(_ view: NSView?, player: AVPlayer) -> [VideoRenderingView] {
        guard let view else { return [] }
        let own = (view as? VideoRenderingView).map { $0.videoLayer.player === player ? [$0] : [] } ?? []
        return own + view.subviews.flatMap { boundPlayers($0, player: player) }
    }
    private static func routePickers(_ view: NSView?, player: AVPlayer) -> [AVRoutePickerView] {
        guard let view else { return [] }
        let own = (view as? AVRoutePickerView).map { $0.player === player ? [$0] : [] } ?? []
        return own + view.subviews.flatMap { routePickers($0, player: player) }
    }
    private static func entered(_ presenter: PlaybackFullscreenPresenter) throws -> NSWindow {
        guard let window = presenter.window else { throw TVError.message("Fullscreen window missing") }
        presenter.windowDidEnterFullScreen(Notification(name: NSWindow.didEnterFullScreenNotification, object: window)); return window
    }
    private static func exited(_ presenter: PlaybackFullscreenPresenter, window: NSWindow) {
        presenter.windowDidExitFullScreen(Notification(name: NSWindow.didExitFullScreenNotification, object: window))
    }
    private static func capture(_ window: NSWindow, name: String) throws {
        guard !window.isVisible, let view = window.contentView else { throw TVError.message("Expected our hidden fixture window") }
        view.layoutSubtreeIfNeeded()
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { throw TVError.message("No fullscreen fixture bitmap") }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        guard let data = bitmap.representation(using: .png, properties: [:]) else { throw TVError.message("No fullscreen image") }
        try data.write(to: URL(fileURLWithPath: ".build/\(name).png")); print("Rendered hidden fullscreen fixture: \(name)")
    }
    static func run(store: AppStore, driver: FullscreenFixtureDriver, base: URL) async throws {
        let presenter = store.fullscreen, player = store.player.player
        let inline = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1060, height: 800), styleMask: .borderless, backing: .buffered, defer: false)
        inline.isReleasedWhenClosed = false
        inline.contentView = NSHostingView(rootView: PlaybackView().environmentObject(store).preferredColorScheme(.dark).background(Theme.background))
        defer { presenter.closeImmediately(); inline.contentView = nil; inline.close() }
        try await Task.sleep(nanoseconds: 200_000_000)
        try require(boundPlayers(inline.contentView, player: player).count == 1, "Inline player is missing")
        try require(player.allowsExternalPlayback && routePickers(inline.contentView, player: player).count == 1, "Inline AirPlay picker is not bound to the active player")
        try require(!store.player.seekRelative(by: 15), "Live playback should not consume seek shortcuts")
        let renderer = store.player.videoSurface.view, layer = store.player.videoSurface.view.videoLayer
        try require(renderer.layer === layer, "Video view is not backed by its persistent AVPlayerLayer")
        let liveItem = player.currentItem
        player.pause(); let pausedPosition = player.currentTime().seconds
        presenter.show(store: store); let liveWindow = try entered(presenter)
        try await Task.sleep(nanoseconds: 250_000_000)
        try require(presenter.isPresented && !liveWindow.isVisible, "Live fullscreen presentation failed")
        try require(boundPlayers(inline.contentView, player: player).isEmpty && boundPlayers(liveWindow.contentView, player: player).count == 1, "Both inline and fullscreen player views are attached")
        try require(boundPlayers(liveWindow.contentView, player: player).first === renderer && renderer.videoLayer === layer && layer.player === player, "Fullscreen replaced or disconnected the renderer")
        try require(player.currentItem === liveItem && player.rate == 0 && abs(player.currentTime().seconds - pausedPosition) < 0.15, "Fullscreen changed paused live playback")
        try require(routePickers(liveWindow.contentView, player: player).count == 1 && routePickers(inline.contentView, player: player).isEmpty, "Fullscreen AirPlay picker lost the active player or left an old picker attached")
        try capture(liveWindow, name: "fullscreen-live")
        try capture(inline, name: "fullscreen-inline-placeholder")
        let exitCount = driver.exits
        presenter.close(); presenter.close()
        try require(driver.exits == exitCount + 1, "Repeated exit started duplicate transitions")
        exited(presenter, window: liveWindow); try await Task.sleep(nanoseconds: 200_000_000)
        try require(!presenter.isPresented && presenter.window == nil && player.currentItem === liveItem && player.rate == 0, "Exit lost live player state")
        try require(boundPlayers(inline.contentView, player: player).count == 1, "Inline player did not reattach")
        try require(player.allowsExternalPlayback && routePickers(inline.contentView, player: player).count == 1, "Returning from fullscreen disabled AirPlay")

        // Validate shortcut metadata without sending input to any window.
        let modifierCases: [NSEvent.ModifierFlags] = [[.command, .control], [.command], [.command, .control, .shift]]
        for modifiers in modifierCases {
            guard let key = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0, windowNumber: inline.windowNumber, context: nil, characters: "f", charactersIgnoringModifiers: "f", isARepeat: false, keyCode: 3) else { throw TVError.message("No shortcut metadata") }
            try require(NativePlayerView.Coordinator.isFullscreenShortcut(key) == (modifiers == [.command, .control]), "Fullscreen shortcut swallowed another command")
        }
        let arrowModifiers: [NSEvent.ModifierFlags] = [[], [.shift], [.command], [.option], [.control]]
        for (code, expected) in [(UInt16(123), Double(-3)), (UInt16(124), Double(3))] {
            for modifiers in arrowModifiers {
                guard let key = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0, windowNumber: inline.windowNumber, context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: code) else { throw TVError.message("No seek shortcut metadata") }
                try require(NativePlayerView.Coordinator.seekOffset(for: key) == (modifiers.isEmpty ? expected : nil), "Arrow shortcut captured a modified key or used the wrong direction")
            }
            guard let heldKey = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: inline.windowNumber, context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: true, keyCode: code) else { throw TVError.message("No repeated-arrow metadata") }
            try require(NativePlayerView.Coordinator.seekOffset(for: heldKey) == expected, "Held arrow keys must continue adjusting playback")
        }
        try require(NativePlayerView.Coordinator.preservesArrowKeys(for: NSTextView()) && NativePlayerView.Coordinator.preservesArrowKeys(for: NSSlider()) && !NativePlayerView.Coordinator.preservesArrowKeys(for: NSView()), "Arrow shortcuts must preserve editing and control focus")

        let line = PlayLine(name: "本地测试", episodes: [Episode(name: "第一集", url: base.appendingPathComponent("test.mp4").absoluteString + "?fullscreen=1"), Episode(name: "第二集", url: base.appendingPathComponent("test.mp4").absoluteString + "?fullscreen=2")])
        store.play(video: Video(id: "fullscreen-fixture", title: "全屏播放验证", lines: [line]), site: nil, line: line, index: 0)
        try await CheckLiveOverlay.ready(store); store.player.setRate(1.25)
        let vodItem = player.currentItem, before = player.currentTime().seconds
        presenter.toggle(store: store); let vodWindow = try entered(presenter)
        try await Task.sleep(nanoseconds: 300_000_000)
        try require(player === store.player.player && player.currentItem === vodItem && player.rate == 1.25 && player.currentTime().seconds > before + 0.05, "VOD fullscreen restarted or paused playback")
        try require(boundPlayers(inline.contentView, player: player).isEmpty && boundPlayers(vodWindow.contentView, player: player).count == 1, "VOD uses duplicate video surfaces")
        try require(routePickers(vodWindow.contentView, player: player).count == 1, "VOD fullscreen has no AirPlay picker")
        try capture(vodWindow, name: "fullscreen-vod")
        store.nextEpisode(); try await CheckLiveOverlay.ready(store)
        try require(presenter.window === vodWindow && presenter.isPresented && store.playback?.index == 1, "Next episode unexpectedly closed fullscreen")
        presenter.close(); exited(presenter, window: vodWindow)

        // A close request during entry is deferred, then exits exactly once.
        presenter.show(store: store); guard let pending = presenter.window else { throw TVError.message("No pending window") }
        let earlyExitCount = driver.exits; presenter.close()
        try require(driver.exits == earlyExitCount && presenter.isPresented, "Entry was interrupted by an unsafe close")
        _ = try entered(presenter); try require(driver.exits == earlyExitCount + 1, "Queued exit was lost")
        exited(presenter, window: pending)
        presenter.windowDidEnterFullScreen(Notification(name: NSWindow.didEnterFullScreenNotification, object: pending))
        try require(!presenter.isPresented, "A stale window callback restored fullscreen")

        presenter.show(store: store); guard let failed = presenter.window else { throw TVError.message("No failure fixture") }
        presenter.windowDidFailToEnterFullScreen(failed)
        try require(!presenter.isPresented && presenter.window == nil && store.alert != nil, "Failed entry left an orphan player window")
        store.alert = nil
        presenter.show(store: store); let retry = try entered(presenter); presenter.close(); presenter.windowDidFailToExitFullScreen(retry)
        let retries = driver.exits; presenter.close(); try require(driver.exits == retries + 1, "Failed exit cannot be retried")
        exited(presenter, window: retry)
        // Repeated handoffs must retain the exact renderer/layer, including
        // the moment after the old host is torn down and before reattachment.
        for _ in 0..<24 {
            presenter.show(store: store); let repeated = try entered(presenter)
            try await Task.sleep(nanoseconds: 20_000_000)
            try require(boundPlayers(repeated.contentView, player: player).first === renderer && layer.player === player, "Repeated entry replaced the layer")
            presenter.close(); exited(presenter, window: repeated)
            try require(layer.player === player, "Exit temporarily cleared the layer's player")
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        guard let originalHost = renderer.superview as? VideoHostView else { throw TVError.message("No restored video host") }
        let oldHost = VideoHostView(surface: store.player.videoSurface), newHost = VideoHostView(surface: store.player.videoSurface)
        store.player.videoSurface.attach(to: oldHost); store.player.videoSurface.attach(to: newHost)
        store.player.videoSurface.detach(from: oldHost)
        try require(renderer.superview === newHost && layer.player === player, "Old host teardown stole the new host's renderer")
        store.player.videoSurface.detach(from: newHost); store.player.videoSurface.attach(to: originalHost)
        player.pause(); player.seek(to: CMTime(seconds: 3, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero, completionHandler: { _ in })
        for _ in 0..<100 {
            if abs(player.currentTime().seconds - 3) < 0.1 { break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        try require(abs(player.currentTime().seconds - 3) < 0.1, "Could not establish an exact seek fixture position")
        try require(store.player.seekRelative(by: 3), "Ready VOD rejected forward seeking")
        try await Task.sleep(nanoseconds: 200_000_000)
        try require(abs(player.currentTime().seconds - 6) < 0.3 && player.rate == 0, "Forward shortcut changed pause state or seek distance: position=\(player.currentTime().seconds), rate=\(player.rate)")
        try require(store.player.seekRelative(by: -3), "Ready VOD rejected backward seeking")
        try await Task.sleep(nanoseconds: 200_000_000)
        try require(abs(player.currentTime().seconds - 3) < 0.3, "Backward shortcut used the wrong distance")
        for _ in 0..<4 { store.player.seekRelative(by: 3) }
        try await Task.sleep(nanoseconds: 200_000_000)
        try require(abs(player.currentTime().seconds - 15) < 0.3, "Rapid forward keys did not accumulate four 3-second steps")
        for _ in 0..<3 { store.player.seekRelative(by: -3) }
        try await Task.sleep(nanoseconds: 200_000_000)
        try require(abs(player.currentTime().seconds - 6) < 0.3, "Rapid backward keys did not accumulate three 3-second steps")
        for _ in 0..<10 { store.player.seekRelative(by: 3) }
        try await Task.sleep(nanoseconds: 200_000_000)
        try require(abs(player.currentTime().seconds - player.currentItem!.duration.seconds) < 0.3, "Rapid arrow keys did not accumulate or clamp at the end")
        for _ in 0..<10 { store.player.seekRelative(by: -3) }
        try await Task.sleep(nanoseconds: 200_000_000)
        try require(player.currentTime().seconds < 0.3 && player.rate == 0 && !store.player.seekRelative(by: .infinity), "Backward seek escaped the start or accepted non-finite input")
        print("PASS: left/right 3-second steps, held-key repeat, modifier and editor/slider exclusions, live exclusion, repeated forward/backward accumulation, bounds and pause preservation")
        let transport = PlaybackTransport(player: player); player.pause(); transport.refresh()
        transport.seek(to: 5); try await Task.sleep(nanoseconds: 250_000_000)
        try require(abs(player.currentTime().seconds - 5) < 0.3 && player.rate == 0, "Custom seek did not preserve pause state")
        let volume = Double(player.volume), muted = player.isMuted
        transport.setVolume(0.32); transport.toggleMute()
        try require(abs(Double(player.volume) - 0.32) < 0.01 && player.isMuted != muted, "Custom volume or mute failed")
        transport.setVolume(volume); if player.isMuted != muted { transport.toggleMute() }
        transport.togglePlayback(rate: 1.25); try await Task.sleep(nanoseconds: 200_000_000)
        try require(player.rate == 1.25 && player.currentTime().seconds > 5.05, "Custom resume lost playback rate")
        transport.togglePlayback(rate: 1.25); try require(player.rate == 0, "Custom pause failed")
        transport.seek(to: transport.duration); try await Task.sleep(nanoseconds: 200_000_000); transport.refresh()
        transport.togglePlayback(rate: 1.25); try await Task.sleep(nanoseconds: 250_000_000)
        try require(player.currentTime().seconds < 1 && player.rate == 1.25, "Play at end did not restart the finite video")
        presenter.show(store: store); presenter.closeImmediately()
        try require(!presenter.isPresented && presenter.window == nil, "Shutdown did not release pending fullscreen")
        store.stop(); let enters = driver.enters; presenter.show(store: store)
        try require(driver.enters == enters && !presenter.isPresented && !driver.everVisible && !inline.isVisible, "Empty playback or fixture visibility guard failed")
        var pickerPresented = false
        let coordinator = AirPlayRoutePicker.Coordinator { pickerPresented = $0 }
        let picker = AVRoutePickerView(frame: .zero)
        coordinator.routePickerViewWillBeginPresentingRoutes(picker)
        try await Task.sleep(nanoseconds: 20_000_000)
        try require(pickerPresented, "System AirPlay picker did not notify controls to remain visible")
        coordinator.routePickerViewDidEndPresentingRoutes(picker)
        try await Task.sleep(nanoseconds: 20_000_000)
        try require(!pickerPresented, "System AirPlay picker left controls pinned after closing")
        print("PASS: inline/live/VOD fullscreen AirPlay pickers share the current AVPlayer; external playback stays enabled and route-dialog visibility callbacks complete")
        print("PASS: persistent renderer/layer across 24 repeated handoffs, old-host teardown isolation, custom seek/pause/rate/volume/mute, live/VOD lifecycle, queued exit, failure cleanup and gesture exclusions")
    }
}
