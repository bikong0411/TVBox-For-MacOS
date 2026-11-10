import SwiftUI
import AppKit
import AVKit
import TVBoxCore

@main struct CheckLiveOverlay {
    @MainActor static func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        guard condition() else { throw TVError.message(message) }
    }
    @MainActor static func ready(_ store: AppStore) async throws {
        for _ in 0..<160 {
            if store.player.ready { return }
            if let error = store.player.error { throw TVError.message(error) }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        throw TVError.message("Local media did not become ready")
    }
    @MainActor static func render<V: View>(_ content: V, name: String, width: Int, height: Int) async throws {
        let hosting = NSHostingView(rootView: content.frame(width: CGFloat(width), height: CGFloat(height)).preferredColorScheme(.dark).tint(Theme.accent))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: height), styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = hosting
        defer { window.close() }
        try await Task.sleep(nanoseconds: 500_000_000); hosting.layoutSubtreeIfNeeded()
        try require(!window.isVisible, "Offscreen fixture window became visible")
        guard let bitmap = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else { throw TVError.message("No bitmap") }
        hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
        guard let data = bitmap.representation(using: .png, properties: [:]) else { throw TVError.message("No image") }
        try data.write(to: URL(fileURLWithPath: ".build/\(name).png"))
        print("Rendered offscreen fixture: \(name)")
    }
    @MainActor static func main() async {
        let application = NSApplication.shared; application.setActivationPolicy(.prohibited)
        guard CommandLine.arguments.contains("--ui-test") else { exit(2) }
        let driver = FullscreenFixtureDriver()
        let store = AppStore(fullscreen: PlaybackFullscreenPresenter(actions: driver.actions))
        store.player.player.isMuted = true
        defer { store.shutdown() }
        do {
            // The production delay is checked against real elapsed time, with
            // cancellation on re-entry and a fresh grace period after activity.
            let visibility = LiveOverlayState()
            try require(!visibility.expanded, "Sidebar must start collapsed")
            visibility.hover(true); try require(visibility.expanded, "Hover must open sidebar")
            visibility.hover(false); try await Task.sleep(nanoseconds: 2_700_000_000)
            try require(visibility.expanded, "Sidebar hid before 3 seconds")
            visibility.hover(true); try await Task.sleep(nanoseconds: 500_000_000)
            try require(visibility.expanded, "Re-entry did not cancel previous timer")
            visibility.hover(false); try await Task.sleep(nanoseconds: 2_000_000_000); visibility.activity()
            try await Task.sleep(nanoseconds: 1_100_000_000)
            try require(visibility.expanded, "Activity did not reset hide deadline")
            try await Task.sleep(nanoseconds: 2_100_000_000)
            try require(!visibility.expanded, "Sidebar did not hide after inactivity")
            visibility.hover(true); visibility.close(); try require(!visibility.expanded, "Explicit close failed")
            print("PASS: real 3-second delay, hover cancellation, activity reset, explicit close")

            let base = URL(string: "http://127.0.0.1:18791/")!
            try await TLSRetryChecks.run(base: base)
            try store.apply(await store.service.configuration(at: base.appendingPathComponent("overlay.m3u")), target: .live)
            for _ in 0..<100 { if store.channels.count == 1000 { break }; try await Task.sleep(nanoseconds: 30_000_000) }
            try require(store.channels.count == 1000, "Large fixture catalogue not loaded")
            let first = store.channels[0], second = store.channels[1], player = store.player.player
            let sourceID = store.sourceLibrary.selectedLiveID, historyCount = store.history.count
            store.playChannel(first); try await ready(store)
            store.playChannel(second); try await ready(store)
            try require(store.player.player === player && store.playback?.video.id == second.id, "Channel switch replaced player or selected wrong channel")
            // Keep a completed programme available just after midnight too.
            let service = ProgrammeGuideService(), day = Date().addingTimeInterval(-2 * 60 * 60)
            let programmes = try await service.programmes(channel: first, day: day)
            try require(!programmes.isEmpty && programmes.allSatisfy { $0.channelID == "c1" }, "EPG matched wrong channel")
            guard let programme = programmes.first(where: { $0.end.map { $0 < Date() } == true }) else { throw TVError.message("No completed fixture programme") }
            store.playCatchup(programme, channel: first); try await ready(store)
            let catchupPosition = player.currentTime().seconds
            try await Task.sleep(nanoseconds: 500_000_000)
            try require(player.currentTime().seconds > catchupPosition + 0.05, "Catchup video clock did not advance")
            try require(store.playback?.catchupProgramme == programme && store.playback?.video.id == first.id, "Catchup did not preserve channel context")
            try require(store.playback?.episode.url.contains("start=") == true, "Catchup template was not expanded")
            store.retryPlayback(); try await ready(store)
            try require(store.playback?.catchupProgramme == programme, "Catchup retry accidentally returned to live")
            store.playChannel(first); try await ready(store)
            try require(store.playback?.catchupProgramme == nil, "Return to live did not clear archive context")
            try require(store.player.player === player && store.history.count == historyCount && store.sourceLibrary.selectedLiveID == sourceID, "Live operations changed history, player or source selection")
            store.switchChannel(1); try await ready(store)
            try require(store.playback?.video.id == second.id, "Next channel navigation failed")
            print("PASS: 1,000 channels, player reuse, local catchup playback/retry, return to live, source/history preserved")

            var jsonChannel = first; jsonChannel.name = "频道 & name=?"; jsonChannel.guide = LiveGuideInfo(url: base.absoluteString + "overlay-epg?ch={name}&date={date}")
            let jsonItems = try await service.programmes(channel: jsonChannel, day: day)
            try require(jsonItems.count == 2 && jsonItems.allSatisfy { $0.channelID == jsonChannel.name }, "TVBox EPG query encoding or channel mapping failed")
            let model = LiveProgrammeModel()
            var slow = first; slow.guide?.url += "?slow=1"
            let old = Task { await model.load(channel: slow, day: day) }
            try await Task.sleep(nanoseconds: 30_000_000)
            await model.load(channel: second, day: day); await old.value
            try require(!model.loading && model.error == nil && model.programmes.allSatisfy { $0.channelID == "c2" }, "Stale EPG response overwrote newer channel")
            print("PASS: TVBox JSON guide, encoded channel names, stale response isolation")

            let generator = AVAssetImageGenerator(asset: AVURLAsset(url: base.appendingPathComponent("test.mp4")))
            generator.appliesPreferredTrackTransform = true
            let frame = try generator.copyCGImage(at: CMTime(seconds: 1, preferredTimescale: 600), actualTime: nil)
            let backdrop = Image(decorative: frame, scale: 1).resizable().scaledToFill()
            for width in [682, 1280] {
                let height = width * 9 / 16
                let open = LiveOverlayState(); open.hover(true)
                let content = ZStack { backdrop; LiveChannelOverlay(browser: store.liveBrowser, visibility: open).environmentObject(store) }.clipped()
                try await render(content, name: "live-overlay-open-\(width)", width: width, height: height)
            }
            let collapsed = LiveOverlayState()
            try await render(ZStack { backdrop; LiveChannelOverlay(browser: store.liveBrowser, visibility: collapsed).environmentObject(store) }.clipped(), name: "live-overlay-collapsed", width: 960, height: 540)
            let openGuide = LiveOverlayState(); openGuide.hover(true)
            try await render(ZStack { backdrop; LiveChannelOverlay(browser: store.liveBrowser, visibility: openGuide, initialGuide: first).environmentObject(store) }.clipped(), name: "live-overlay-guide", width: 960, height: 540)
            try await render(PlaybackView().environmentObject(store).background(Theme.background), name: "live-player-page", width: 1060, height: 850)
            try store.apply(await store.service.configuration(at: base.appendingPathComponent("grouping.m3u")), target: .live)
            for _ in 0..<100 { if store.channels.count == 21 { break }; try await Task.sleep(nanoseconds: 30_000_000) }
            try require(store.channels.count == 21, "Grouped fixture catalogue did not load")
            let browser = store.liveBrowser
            try require(browser.grouping == .automatic, "New installations should use automatic grouping")
            if let i = CommandLine.arguments.firstIndex(of: "--ui-test-suite"), let defaults = UserDefaults(suiteName: CommandLine.arguments[i + 1]) {
                browser.grouping = .original
                try require(LiveBrowserState(defaults: defaults).grouping == .original, "Grouping mode did not persist")
                browser.group = "原始线路 1"; browser.grouping = .automatic
                try require(browser.group == "全部", "Changing grouping mode retained an invalid group")
            }
            let grouped = store.channelIndex.sections(), all = grouped.flatMap(\.channels)
            try require(all.count == 21 && Set(all.map(\.id)) == Set(store.channels.map(\.id)), "Grouping lost channels")
            browser.layout = .list
            try await render(LiveView(browser: browser, probe: store.networkProbe).environmentObject(store).background(Theme.background), name: "live-groups-list", width: 960, height: 1000)
            browser.layout = .grid
            try await render(LiveView(browser: browser, probe: store.networkProbe).environmentObject(store).background(Theme.background), name: "live-groups-grid", width: 960, height: 1000)
            browser.group = "影视剧场"
            let movies = store.channelIndex.sections(group: browser.group).flatMap(\.channels)
            try require(movies.count == 2, "Movie group has unexpected channels")
            store.setLiveNavigation(movies); store.playChannel(movies[0]); try await ready(store)
            store.switchChannel(1); try await ready(store)
            try require(store.playback?.video.id == movies[1].id && !store.canSwitchChannel(1), "Next channel escaped selected group")
            let groupedOpen = LiveOverlayState(); groupedOpen.hover(true)
            try await render(ZStack { backdrop; LiveChannelOverlay(browser: browser, visibility: groupedOpen).environmentObject(store) }.clipped(), name: "live-groups-filtered-overlay", width: 960, height: 540)
            browser.group = "全部"
            let chooserOpen = LiveOverlayState(); chooserOpen.hover(true)
            try await render(ZStack { backdrop; LiveChannelOverlay(browser: browser, visibility: chooserOpen, groupsExpanded: true).environmentObject(store) }.clipped(), name: "live-groups-chooser", width: 682, height: 384)
            print("PASS: automatic/original grouping preference, all channels preserved, group navigation, grouped list/grid/overlay rendered")
            try await FullscreenChecks.run(store: store, driver: driver, base: base)
            store.stop(); try require(store.playback == nil && store.player.player.currentItem == nil, "Stop did not release playback")
            print("PASS: offscreen production overlay / player views rendered; playback stopped cleanly")
        } catch { print("FAIL: \(error.localizedDescription)"); exit(1) }
    }
}
