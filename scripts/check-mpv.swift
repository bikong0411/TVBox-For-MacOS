import AppKit
import TVBoxCore

@main struct CheckMPV {
    @MainActor static func counts() async throws -> [String: Int] {
        let (data, _) = try await URLSession.shared.data(from: URL(string: "http://127.0.0.1:18791/mpv-network/stats")!)
        return try JSONSerialization.jsonObject(with: data) as! [String: Int]
    }
    @MainActor static func require(_ value: @autoclosure () -> Bool, _ message: String) throws { if !value() { throw TVError.message(message) } }
    @MainActor static func wait(_ message: String, controller: PlayerController, until: () -> Bool) async throws {
        for _ in 0..<240 {
            controller.videoSurface.view.layoutSubtreeIfNeeded()
            if let view = controller.mpvSession?.renderingView { view.draw(view.bounds) }
            if until() { return }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        throw TVError.message(message + "; " + (controller.error ?? controller.componentNotice ?? controller.playbackEngine))
    }
    @MainActor static func main() async {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let controller = PlayerController(); controller.preferMPV = true
        let originalIINA = Set(NSRunningApplication.runningApplications(withBundleIdentifier: "com.colliderli.iina").map(\.processIdentifier))
        let window = NSWindow(contentRect: NSRect(x: 0,y: 0,width: 960,height: 540),styleMask: .borderless,backing: .buffered,defer: false)
        window.isReleasedWhenClosed = false
        let host = VideoHostView(surface: controller.videoSurface); window.contentView = host
        controller.videoSurface.attach(to: host); host.layoutSubtreeIfNeeded()
        defer { controller.stop(); window.contentView = nil; window.close() }
        do {
            let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".build")
            controller.setVolume(0)
            let clip = Episode(name: "mpv fixture", url: root.appendingPathComponent("test.mp4").absoluteString)
            // Cancellation before the background bootstrap must not publish
            // a late decoder or switch a replacement input back to VLC.
            controller.play(Episode(name: "cancel before bootstrap", url: "http://127.0.0.1:18791/missing.mp4"), headers: [:])
            controller.play(clip, headers: [:], position: 3)
            try require(controller.mpvSession == nil, "Core initialization ran synchronously in the play action")
            try await wait("libmpv did not decode", controller: controller) { controller.ready && controller.position > 3.3 }
            try require(controller.mpvSession != nil && controller.nativeSession == nil && !controller.systemPlayback, "Playback did not use embedded libmpv")
            try require((controller.mpvSession?.renderingView.framesRendered ?? 0)>0 && controller.duration>25, "Embedded renderer/clock not running")
            controller.pause(); controller.setRate(1.25); controller.seek(to: 3)
            for _ in 0..<4 { try require(controller.seekRelative(by: 3), "3 second seek rejected") }
            try await wait("Accumulated paused seeking failed", controller: controller) { abs(controller.position-15)<0.7 }
            try require(!controller.playing && controller.effectiveRate==1.25, "Pause or rate lost")
            let session = controller.mpvSession, renderer = controller.mpvSession?.renderingView
            for _ in 0..<12 {
                let fullHost = VideoHostView(surface: controller.videoSurface,isFullscreen: true)
                controller.videoSurface.setFullscreenHost(true); controller.videoSurface.attach(to: fullHost)
                controller.videoSurface.setFullscreenHost(false); controller.videoSurface.attach(to: host)
                try require(controller.mpvSession === session && controller.mpvSession?.renderingView === renderer, "Fullscreen restarted the decoder")
            }
            controller.togglePlayback()
            try await wait("Playback did not resume", controller: controller) { controller.position>15.5 }
            let before = controller.position
            controller.prepareAirPlayRoute()
            try await wait("AirPlay preparation stopped local video", controller: controller) { controller.position>before+0.4 }
            try require(controller.ready && controller.mpvSession === session && !controller.systemPlayback, "AirPlay device menu reloaded the route")
            controller.cancelAirPlayPreparation()
            try require(controller.mpvSession === session && controller.player.currentItem == nil && !controller.systemPlayback, "Canceling AirPlay destroyed embedded playback")
            print("PASS: in-app libmpv decode/render, progress, pause, rate, 3s seek and 12 fullscreen handoffs; AirPlay prepare/cancel preserves decoder")
            for file in ["test.flv","test.mkv","test-mpeg2.ts"] {
                controller.play(Episode(name: file,url: root.appendingPathComponent(file).absoluteString),headers: [:])
                try await wait("Format decode failed "+file, controller: controller) { controller.ready && controller.position>0.1 }
                try require(controller.mpvSession != nil,"Format fell back unexpectedly")
            }
            controller.play(Episode(name: "auth",url: "http://127.0.0.1:18791/test.mp4?require-retry-header=1"),headers: ["X-Retry-Fixture":"preserved"])
            try await wait("mpv custom auth failed", controller: controller) { controller.ready && controller.position>0.1 }
            try require(!controller.systemPlayback && controller.mpvSession != nil, "Custom headers forced a system reload")
            let firstStart = Date()
            controller.play(Episode(name: "network compatibility HLS", url: "http://127.0.0.1:18791/mpv-network/master.m3u8?slow-direct=1"), headers: ["X-MPV-Network": "preserved"], position: 3)
            try await wait("System-network HLS retry did not decode", controller: controller) { controller.ready && controller.position>3.3 }
            try require(controller.mpvSession != nil && controller.nativeSession == nil && !controller.systemPlayback, "Network retry switched away from embedded mpv")
            try require(controller.componentNotice?.contains("兼容连接") == true, "Network retry was not reported")
            let firstElapsed = Date().timeIntervalSince(firstStart), initialCounts = try await counts()
            try require((initialCounts["direct"] ?? 0)>0 && (initialCounts["playlist"] ?? 0)>=2 && (initialCounts["segment"] ?? 0)>0, "Retry lost headers, redirect base or HLS segment routing")
            let networkSession = controller.mpvSession
            controller.pause(); controller.seek(to: 6); controller.setRate(1.25)
            controller.prepareAirPlayRoute(); controller.cancelAirPlayPreparation()
            try require(controller.mpvSession === networkSession && !controller.playing, "Casting menu reloaded the compatible decoder")
            let rememberedStart = Date()
            controller.play(Episode(name: "next episode remembered connection", url: "http://127.0.0.1:18791/mpv-network/master.m3u8?episode=2"), headers: ["X-MPV-Network": "preserved"], position: 3)
            try await wait("Remembered connection did not decode", controller: controller) { controller.ready && controller.position>3.3 }
            let rememberedElapsed = Date().timeIntervalSince(rememberedStart), reusedCounts = try await counts()
            try require(reusedCounts["direct"] == initialCounts["direct"], "Remembered connection repeated the failed direct path")
            try require(controller.componentNotice?.contains("复用成功连接") == true && controller.rate == 1.25, "Remembered connection lost its notice or playback rate")
            print(String(format: "MEASURE: controlled 1s direct failure, initial start %.3fs → remembered next episode %.3fs; failed direct requests unchanged", firstElapsed, rememberedElapsed))
            controller.play(Episode(name: "same-origin live input", url: "http://127.0.0.1:18791/mpv-network/direct-only.m3u8"), headers: ["X-MPV-Network": "preserved"], isLive: true)
            try await wait("Live input used VOD connection memory", controller: controller) { controller.ready && controller.position>0.1 }
            let liveCounts = try await counts()
            try require(liveCounts["relay_rejected"] == reusedCounts["relay_rejected"] && controller.componentNotice == nil, "Live playback entered remembered relay")
            controller.play(Episode(name: "changed authentication context", url: "http://127.0.0.1:18791/mpv-network/master.m3u8"), headers: ["X-MPV-Network": "preserved", "X-Variant": "different"])
            try await wait("Changed request context did not retry independently", controller: controller) { controller.ready && controller.position>0.1 }
            let differentCounts = try await counts()
            try require((differentCounts["direct"] ?? 0) > (liveCounts["direct"] ?? 0), "Request header change reused an unrelated preference")
            controller.play(Episode(name: "remembered relay now fails", url: "http://127.0.0.1:18791/mpv-network/direct-only.m3u8"), headers: ["X-MPV-Network": "preserved"], position: 3)
            try await wait("Failed remembered relay did not fall back to direct", controller: controller) { controller.ready && controller.position>3.3 }
            let fallbackCounts = try await counts()
            try require((fallbackCounts["relay_rejected"] ?? 0) > (differentCounts["relay_rejected"] ?? 0) && controller.componentNotice == nil, "Preferred relay failure did not return to direct mpv")
            controller.play(Episode(name: "discarded failed hint", url: "http://127.0.0.1:18791/mpv-network/direct-only.m3u8?episode=3"), headers: ["X-MPV-Network": "preserved"])
            try await wait("Direct play after forgetting hint failed", controller: controller) { controller.ready && controller.position>0.1 }
            let forgottenCounts = try await counts()
            try require(forgottenCounts["relay_rejected"] == fallbackCounts["relay_rejected"], "A failed remembered hint was retained")
            print("PASS: verified connection reused for next episode; live and changed headers isolated; stale relay hint falls back once and is forgotten")
            controller.play(clip, headers: [:])
            try await wait("Switching away from network retry failed", controller: controller) { controller.ready && controller.position>0.2 }
            try require(controller.mpvSession !== networkSession && controller.componentNotice == nil, "Compatibility leaked into the next video")
            print("PASS: failed direct HTTP → system-network retry, authenticated HLS master/media/segment, relative redirects, resume position, cast menu and video switching")
            controller.seek(to: controller.duration-0.2)
            try await wait("End of file was not detected", controller: controller) { controller.mpvSession?.reachedEnd == true }
            controller.togglePlayback()
            try await wait("Replay did not return to the start", controller: controller) { controller.playing && controller.position<5 }
            controller.play(Episode(name: "invalid network fixture", url: "http://127.0.0.1:18791/mpv-network/invalid.m3u8"), headers: ["X-MPV-Network": "preserved"])
            try await wait("A failed compatibility retry did not stop", controller: controller) { controller.error != nil }
            try require(controller.failure?.diagnostic.contains("mpv") == true && controller.error?.contains("已自动重试 1 次") == true && !controller.ready, "Final failure lost its mpv diagnostic or retry limit")
            controller.play(Episode(name: "cancel network fixture", url: "http://127.0.0.1:18791/mpv-network/slow.m3u8"), headers: ["X-MPV-Network": "preserved"])
            try await wait("Slow fixture did not enter compatibility", controller: controller) { controller.componentNotice != nil }
            controller.play(clip, headers: [:])
            try await wait("Switching during compatibility failed", controller: controller) { controller.ready && controller.position>0.2 }
            let replacement = controller.mpvSession
            try await Task.sleep(nanoseconds: 2_000_000_000)
            try require(controller.mpvSession === replacement && controller.ready && controller.error == nil, "Cancelled network input overwrote the next video")
            print("PASS: final failure includes mpv code; cancelling an in-flight compatible input preserves the next video")

            var routes: [Int] = []
            let started = ContinuousClock.now
            controller.playLive([
                Episode(name: "Slow", url: "http://127.0.0.1:18791/slow.mp4"),
                Episode(name: "Backup", url: "http://127.0.0.1:18791/test.mp4")
            ], index: 0, headers: [:]) { routes.append($0) }
            try await wait("Backup did not take over from a stalled mpv stream", controller: controller) {
                controller.ready && controller.position > 0.3 && routes.last == 1
            }
            try require(routes == [0, 1] && controller.mpvSession == nil && controller.nativeSession != nil, "Backup left the old decoder active")
            try require(ContinuousClock.now - started < .seconds(8), "Backup waited too long to take over")
            print("PASS: decoded VLC backup took over from stalled mpv")

            controller.stop()
            try require(controller.mpvSession == nil && controller.nativeSession == nil && !controller.ready,"Stop leaked a decoder")
            let finalIINA = Set(NSRunningApplication.runningApplications(withBundleIdentifier: "com.colliderli.iina").map(\.processIdentifier))
            try require(originalIINA == finalIINA,"Embedding opened or terminated IINA")
            print("PASS: FLV/MKV/MPEG-2 TS, custom authentication, teardown; IINA application processes unchanged")
            print("ALL EMBEDDED MPV CHECKS PASSED")
        } catch { fputs("FAIL: \(error.localizedDescription)\n",stderr);exit(1) }
    }
}
