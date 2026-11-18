import AppKit
import Foundation
import TVBoxCore

@main struct CheckCSPPlayback {
    @MainActor static func require(_ value: @autoclosure () -> Bool, _ text: String) throws {
        if !value() { throw TVError.message(text) }
    }
    @MainActor static func wait(_ text: String, seconds: Double = 30, until: () -> Bool) async throws {
        for _ in 0..<Int(seconds * 20) {
            if until() { return }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        throw TVError.message(text)
    }
    @MainActor static func main() async {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let store = AppStore()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 960, height: 540), styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let host = VideoHostView(surface: store.player.videoSurface)
        window.contentView = host; store.player.videoSurface.attach(to: host); host.layoutSubtreeIfNeeded()
        defer { store.shutdown(); window.contentView = nil; window.close() }
        do {
            let environment = ProcessInfo.processInfo.environment
            let fixture = try environment["CSP_FIXTURE"].unwrap("Missing fixture")
            let media = try environment["CSP_TEST_MEDIA"].unwrap("Missing media")
            let definition = try CSPDefinition(component: CSPComponent(URL(fileURLWithPath: fixture).absoluteString), api: "csp_CSPFixture", extend: media)
            let site = Site(key: "synthetic", name: "CSP 独立测试", type: 3, api: "csp_CSPFixture", headers: ["Referer": "https://fixture.invalid/"], csp: definition)
            try store.apply(Configuration(name: "CSP 测试配置", location: "https://fixture.invalid/csp.json", sites: [site]), target: .vod)
            try await wait("CSP discovery did not finish") { !store.loading }
            try require(store.catalogError == nil && store.videos.count == 1 && store.categories.count == 1 && store.supportedSites.count == 1, "CSP discovery/source selection failed")
            let selected = try store.site.unwrap("Missing scoped source")
            let detail = try await store.service.detail(video: store.videos[0], site: selected)
            let line = detail.lines[0]
            try require(line.episodes.count == 2 && line.episodes[0].url == "opaque:first$token", "CSP detail changed playback IDs")
            print("PASS: isolated AppStore imports, selects and browses a real DEX fixture")
            store.player.setVolume(0)
            store.play(video: detail, site: selected, line: line, index: 0)
            do { try await wait("CSP video did not start", seconds: 60) { store.player.ready || store.player.error != nil } }
            catch {
                print("CSP test state: resolved", store.playback?.resolvedEpisode != nil, "VLC", store.player.nativeSession?.player.state.rawValue ?? -1, "system",store.player.systemPlayback,"status",store.player.connectingMessage)
                throw error
            }
            if store.player.error != nil || !store.player.ready || store.player.nativeSession == nil {
                print("CSP test state: resolved",store.playback?.resolvedEpisode != nil,"VLC",store.player.nativeSession?.player.state.rawValue ?? -1,"system",store.player.systemPlayback,"error",store.player.error ?? "none")
            }
            try require(store.player.error == nil && store.player.ready && store.player.nativeSession != nil, "Resolved CSP video did not use embedded VLC")
            try await wait("CSP video clock stalled") { store.player.position > 0.3 && store.player.duration > 25 }
            try require(store.playback?.resolvedEpisode?.url == media && store.playback?.headers["User-Agent"] == "TVBoxCSPFixture", "Resolution lost URL or headers")
            try require(store.history.first?.episode?.url == "opaque:first$token", "History lost original CSP playback ID")
            store.player.pause(); store.player.seek(to: 6); store.player.setRate(1.25)
            try await wait("CSP controls did not preserve seek") { abs(store.player.position - 6) < 0.5 && !store.player.playing }
            print("PASS: CSP resolution, authenticated media request, embedded VLC, progress, pause, seek, rate and original history ID")
            let proxyLine = PlayLine(name: "测试线路", episodes: [Episode(name: "代理媒体", url: "opaque:proxy")])
            store.play(video: detail, site: selected, line: proxyLine, index: 0)
            try await wait("CSP proxy video did not start", seconds: 60) { store.player.ready || store.player.error != nil }
            try require(store.player.error == nil && store.player.nativeSession != nil && store.playback?.cspLease != nil, "CSP proxy was not owned by embedded playback")
            try await wait("CSP proxy decoder did not advance") { store.player.position > 0.3 && store.player.duration > 25 }
            store.player.pause(); store.player.seek(to: 8)
            try await wait("CSP proxy seek failed") { abs(store.player.position - 8) < 0.5 && !store.player.playing }
            let temporaryProxy = store.playback!.resolvedEpisode!.url
            store.stop()
            try await Task.sleep(nanoseconds: 300_000_000)
            do { _ = try await URLSession.shared.data(from: URL(string: temporaryProxy)!); throw TVError.message("Stopped CSP proxy remained accessible") }
            catch is URLError { }
            print("PASS: standard Java proxy callback, streamed MP4 decode, range seek and stop endpoint cleanup")
            let slow = PlayLine(name: "测试线路", episodes: [Episode(name: "旧请求", url: "opaque:slow")])
            store.play(video: detail, site: selected, line: slow, index: 0)
            try await Task.sleep(nanoseconds: 100_000_000)
            store.stop()
            store.play(video: detail, site: selected, line: line, index: 1)
            try await wait("Next CSP episode did not start") { store.player.ready || store.player.error != nil }
            try await Task.sleep(nanoseconds: 1_200_000_000)
            try require(store.player.ready && store.player.error == nil && store.playback?.index == 1 && store.playback?.resolvedEpisode?.name == line.episodes[1].name, "Cancelled resolution replaced the current episode")
            store.stop()
            try require(store.playback == nil && store.player.nativeSession == nil && !store.player.ready, "Stop left CSP playback active")
            print("PASS: stop / next episode reject stale asynchronous resolution and release the decoder")
            print("ALL CSP PLAYBACK CHECKS PASSED")
        } catch { fputs("FAIL: " + error.localizedDescription + "\n", stderr); exit(1) }
    }
}
private extension Optional {
    func unwrap(_ message: String) throws -> Wrapped { guard let value = self else { throw TVError.message(message) }; return value }
}
