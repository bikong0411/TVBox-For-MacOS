import AppKit
import SwiftUI
import AVFoundation
import TVBoxCore
import VLCKit

@main struct CheckVLCPlayback {
    @MainActor static func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() { throw TVError.message(message) }
    }
    @MainActor static func wait(_ message: String, seconds: Double = 12, until: () -> Bool) async throws {
        for _ in 0..<Int(seconds * 20) {
            if until() { return }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        throw TVError.message(message)
    }
    @MainActor static func main() async {
        let app = NSApplication.shared; app.setActivationPolicy(.prohibited)
        let controller = PlayerController()
        let transport = PlaybackTransport(controller: controller)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 960, height: 540), styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let host = VideoHostView(surface: controller.videoSurface)
        window.contentView = host; controller.videoSurface.attach(to: host); host.layoutSubtreeIfNeeded()
        defer { controller.stop(); window.contentView = nil; window.close() }
        do {
            let base = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".build")
            controller.setVolume(0); controller.toggleMute()
            let clip = Episode(name: "本地测试", url: base.appendingPathComponent("test.mp4").absoluteString)
            controller.play(clip, headers: [:], position: 3)
            try await wait("VLC did not become ready") { controller.ready || controller.error != nil }
            try require(controller.ready && !controller.systemPlayback && controller.nativeSession != nil, "Default playback did not use bundled VLC")
            try await wait("VLC clock did not advance") { controller.position > 3.2 && controller.duration > 25 }
            transport.refresh()
            try require(transport.playing && transport.canSeek && transport.duration > 25, "Control bar did not show decoder state")
            transport.setVolume(0.4); transport.toggleMute()
            try require(controller.nativeSession?.player.audio?.volume == 40 && !controller.muted, "Control bar volume or mute did not reach VLC")
            transport.setVolume(0); transport.toggleMute()
            transport.togglePlayback(rate: 1)
            try await wait("VLC pause failed") { !controller.playing }
            controller.setRate(1.25)
            transport.refresh()
            try require(abs(transport.effectiveRate - 1.25) < 0.01 && !transport.playing, "Control bar rate/pause state incorrect")
            let paused = controller.position
            try await Task.sleep(nanoseconds: 300_000_000)
            try require(abs(controller.position - paused) < 0.2, "Paused VLC clock advanced")
            controller.seek(to: 3)
            try await wait("VLC precise seek failed") { abs(controller.position - 3) < 0.4 }
            for _ in 0..<4 { try require(controller.seekRelative(by: 3), "Arrow seek was rejected") }
            do { try await wait("Rapid seek steps were lost") { abs(controller.position - 15) < 0.5 } }
            catch { print("Seek observed:", controller.position, "native state", controller.nativeSession?.player.state.rawValue ?? -1, "seekable", controller.nativeSession?.seekable ?? false); throw error }
            try require(!controller.playing, "Seeking resumed paused playback")
            let session = controller.nativeSession, renderer = controller.videoSurface.view
            let fullHost = VideoHostView(surface: controller.videoSurface, isFullscreen: true)
            let full = NSWindow(contentRect: window.frame, styleMask: .borderless, backing: .buffered, defer: false)
            full.isReleasedWhenClosed = false; full.contentView = fullHost
            for _ in 0..<24 {
                controller.videoSurface.setFullscreenHost(true); controller.videoSurface.attach(to: fullHost)
                controller.videoSurface.attach(to: host)
                try require(renderer.superview === fullHost && controller.nativeSession === session, "Fullscreen lost the VLC session or renderer")
                controller.videoSurface.detach(from: host)
                controller.videoSurface.setFullscreenHost(false); controller.videoSurface.attach(to: host)
                controller.videoSurface.detach(from: fullHost)
                try require(renderer.superview === host && controller.nativeSession === session, "Inline handoff lost the VLC session")
            }
            full.contentView = nil; full.close()
            try require(abs(controller.position - 15) < 0.5 && controller.rate == 1.25, "Fullscreen changed position or rate")
            print("PASS: bundled VLC playback, resume, clock, pause, rate, accumulated 3s seeking and 24 fullscreen handoffs")

            controller.togglePlayback()
            try await wait("VLC decoder did not apply paused seek") {
                guard let session = controller.nativeSession else { return false }
                let actual = Double(session.player.time.intValue) / 1000
                return actual >= 14.5 && actual < 19
            }
            controller.pause()
            controller.seek(to: 15)
            controller.useSystemPlayback()
            try await wait("System AirPlay path did not become ready") { controller.ready && controller.systemPlayback }
            try await wait("System mode lost playback position") { abs(controller.position - 15) < 0.6 }
            try require(controller.nativeSession == nil && !controller.playing && controller.rate == 1.25, "Switching to AirPlay changed pause/rate or left VLC running")
            controller.useVLCPlayback()
            try await wait("Returning to VLC failed") { controller.ready && !controller.systemPlayback }
            try await wait("Returning to VLC lost position") { abs(controller.position - 15) < 0.6 }
            try require(!controller.playing && controller.muted && controller.volume == 0, "Returning to VLC lost transport state")
            try await Task.sleep(nanoseconds: 300_000_000)
            try require(!controller.buffering, "Paused VLC incorrectly showed buffering")
            print("PASS: system AirPlay/PiP path and return to VLC preserve pause, position, rate and volume")

            for file in ["test.flv", "test.mkv", "test-mpeg2.ts"] {
                controller.play(Episode(name: file, url: base.appendingPathComponent(file).absoluteString), headers: [:])
                try await wait("VLC failed to decode " + file) { controller.ready || controller.error != nil }
                try require(controller.ready && !controller.systemPlayback, "Format did not use VLC: " + file)
                try await wait("VLC format clock stalled: " + file) { controller.position > 0.2 }
            }
            print("PASS: FLV, MKV and MPEG-2 TS decode directly in bundled VLC")

            let server = "http://127.0.0.1:18791/"
            controller.play(Episode(name: "请求头", url: server + "test.mp4?require-vlc-headers=1"), headers: ["User-Agent": "TVBox-VLC-Fixture", "Referer": "https://fixture.invalid/"])
            try await wait("VLC UA/Referer request failed") { controller.ready || controller.error != nil }
            try require(controller.ready && !controller.systemPlayback, "VLC lost UA/Referer")
            controller.play(Episode(name: "自定义鉴权", url: server + "test.mp4?require-retry-header=1"), headers: ["X-Retry-Fixture": "preserved"])
            try await wait("Custom header compatibility failed") { controller.ready || controller.error != nil }
            try require(controller.ready && controller.systemPlayback, "Custom header was dropped")
            print("PASS: VLC UA/Referer and custom-header compatibility preserve headers")

            var routes: [Int] = []
            controller.playLive([Episode(name: "失效", url: server + "invalid-live.flv"), Episode(name: "备用", url: server + "test.mp4")], index: 0, headers: [:]) { routes.append($0) }
            do { try await wait("Invalid VLC route did not fall back", seconds: 38) { controller.ready && routes.last == 1 } }
            catch { print("Routes:", routes, "state:", controller.nativeSession?.player.state.rawValue ?? -1, "ready:", controller.ready, "error:", controller.error ?? "none"); throw error }
            try require(routes == [0, 1] && !controller.systemPlayback, "Live fallback repeated a route or used external playback")
            try require(!controller.seekRelative(by: 3), "Live playback consumed arrow seek")
            controller.play(Episode(name: "无效", url: server + "invalid-live.flv"), headers: [:])
            try await wait("Invalid VLC input never terminated", seconds: 38) { controller.error != nil }
            try require(controller.error?.contains("已自动重试 1 次") == true && controller.nativeSession == nil, "VLC retry was not bounded or error not readable")
            controller.play(Episode(name: "旧请求", url: server + "invalid-live.flv"), headers: [:])
            controller.play(clip, headers: [:])
            try await wait("Switch after failure did not recover") { controller.ready }
            try await Task.sleep(nanoseconds: 1_000_000_000)
            try require(controller.ready && controller.error == nil, "Cancelled VLC callback replaced the new request")
            controller.stop()
            try require(controller.nativeSession == nil && controller.player.currentItem == nil && !controller.ready, "Stop left a playback engine active")
            print("PASS: invalid input retry, alternate live routes, cancellation isolation and stop cleanup")
            print("ALL VLC PLAYBACK CHECKS PASSED")
        } catch {
            fputs("FAIL: " + error.localizedDescription + "\n", stderr); exit(1)
        }
    }
}
