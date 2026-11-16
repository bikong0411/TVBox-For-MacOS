import AppKit
import TVBoxCore

@main struct CheckMPV {
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
            controller.play(clip, headers: [:], position: 3)
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
            controller.seek(to: controller.duration-0.2)
            try await wait("End of file was not detected", controller: controller) { controller.mpvSession?.reachedEnd == true }
            controller.togglePlayback()
            try await wait("Replay did not return to the start", controller: controller) { controller.playing && controller.position<5 }
            controller.stop()
            try require(controller.mpvSession == nil && controller.nativeSession == nil && !controller.ready,"Stop leaked a decoder")
            let finalIINA = Set(NSRunningApplication.runningApplications(withBundleIdentifier: "com.colliderli.iina").map(\.processIdentifier))
            try require(originalIINA == finalIINA,"Embedding opened or terminated IINA")
            print("PASS: FLV/MKV/MPEG-2 TS, custom authentication, teardown; IINA application processes unchanged")
            print("ALL EMBEDDED MPV CHECKS PASSED")
        } catch { fputs("FAIL: \(error.localizedDescription)\n",stderr);exit(1) }
    }
}
