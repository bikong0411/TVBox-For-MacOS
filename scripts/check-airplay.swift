import AppKit
import AVFoundation
import TVBoxCore

/// Route selection is injected through the same event handler as KVO. The
/// media, AVPlayer, native decoder, seeking and watchdogs are real; no TV is
/// contacted by these checks. Physical receiver output needs a separate test.
@main struct CheckAirPlay {
    @MainActor static func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() { throw TVError.message(message) }
    }
    @MainActor static func wait(_ message: String, seconds: Double = 12, _ condition: () -> Bool) async throws {
        for _ in 0..<Int(seconds * 20) {
            if condition() { return }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        throw TVError.message(message)
    }
    @MainActor static func main() async {
        NSApplication.shared.setActivationPolicy(.prohibited)
        do {
            for mpv in [false, true] {
                let controller = PlayerController(airPlayStartTimeout: 4); controller.preferMPV = mpv; controller.setVolume(0)
                let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 360), styleMask: .borderless, backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false
                let host = VideoHostView(surface: controller.videoSurface); window.contentView = host; controller.videoSurface.attach(to: host)
                defer { controller.stop(); window.contentView = nil; window.close() }
                let clip = Episode(name: "AirPlay test", url: URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".build/test.mp4").absoluteString)
                controller.play(clip, headers: [:], position: 3)
                try await wait("Native decoder did not start") { controller.ready && controller.position > 3.2 }
                let native = controller.nativeSession, component = controller.mpvSession
                controller.prepareAirPlayRoute()
                try await wait("AirPlay candidate did not preload") { controller.player.currentItem?.status == .readyToPlay }
                try require(!controller.airPlayConnected && !controller.systemPlayback && controller.playing, "Opening the picker falsely marked AirPlay successful or stopped local playback")
                controller.player.allowsExternalPlayback = false
                controller.airPlayRouteChanged(true)
                try require(!controller.airPlayConnected && !controller.systemPlayback, "Route selection was mistaken for completed playback")
                try await wait("Selected route did not start a real AVPlayer clock") { controller.airPlayConnected && controller.systemPlayback }
                try require(controller.player.currentTime().seconds > 3 && controller.player.rate > 0, "Handoff lost progress or never started transport")
                try require(controller.nativeSession === native && controller.mpvSession === component, "Handoff destroyed the original decoder")
                controller.airPlayRouteChanged(false)
                try await wait("Disconnect did not restore native decoder") { !controller.systemPlayback && controller.playing }
                controller.pause()
                let pausedAt = controller.position
                controller.prepareAirPlayRoute(); controller.player.allowsExternalPlayback = false; controller.airPlayRouteChanged(true)
                try await wait("Paused handoff never connected") { controller.airPlayConnected && controller.systemPlayback }
                try require(!controller.playing && abs(controller.position - pausedAt) < 1.5, "Paused handoff lost pause or progress")
                controller.airPlayRouteChanged(false)
                try require(!controller.systemPlayback && !controller.playing && !controller.airPlayConnected, "Disconnect lost the paused state")
                print("PASS:", mpv ? "mpv" : "VLC", "route selection is not success; actual AVPlayer progress commits handoff; pause, resume, disconnect preserve native decoder")

                controller.useSystemPlayback()
                try await wait("System playback did not load") { controller.ready && controller.systemPlayback }
                controller.pause(); controller.player.allowsExternalPlayback = false; controller.airPlayRouteChanged(true)
                try await wait("Existing system output never confirmed") { controller.airPlayConnected }
                try require(!controller.playing, "Confirming an existing paused system output lost pause")
                controller.airPlayRouteChanged(false)
                try require(controller.systemPlayback && !controller.airPlayConnected && !controller.playing, "System output disconnect changed local pause")
                print("PASS: existing system player confirms actual progress and preserves pause across route selection / disconnect")

                controller.play(Episode(name: "Stalled AirPlay fixture", url: "http://127.0.0.1:18791/test.mp4?airplay-stall=1"), headers: [:], position: 3)
                try await wait("Stall fixture did not play in native decoder") { controller.ready && controller.position > 3.1 }
                controller.pause()
                controller.prepareAirPlayRoute(); controller.player.allowsExternalPlayback = false; controller.airPlayRouteChanged(true)
                try await wait("Stalled route did not time out", seconds: 8) { !controller.airPlayPreparing && controller.airPlayMessage != nil }
                try require(!controller.airPlayConnected && !controller.systemPlayback && controller.ready && !controller.playing, "Timed-out route falsely reported success or changed local pause")
                controller.prepareAirPlayRoute(); controller.player.allowsExternalPlayback = false; controller.airPlayRouteChanged(true)
                controller.play(clip, headers: [:])
                try await wait("Replacement video did not start") { controller.ready && controller.position > 0.2 }
                try await Task.sleep(nanoseconds: 5_000_000_000)
                try require(controller.ready && !controller.systemPlayback && !controller.airPlayConnected && controller.airPlayMessage == nil && controller.error == nil, "Old route completion/timeout overwrote replacement playback")
                print("PASS:", mpv ? "mpv" : "VLC", "stalled remote transport times out, retains native pause and never overwrites a new video")
                controller.stop()
            }
            print("ALL AIRPLAY HANDOFF CHECKS PASSED (simulated route selection, real media playback)")
        } catch { fputs("FAIL: \(error.localizedDescription)\n", stderr); exit(1) }
    }
}
