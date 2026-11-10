import Foundation
import AVFoundation
import TVBoxCore

@MainActor enum TLSRetryChecks {
    static func require(_ value: @autoclosure () -> Bool, _ message: String) throws {
        guard value() else { throw TVError.message(message) }
    }
    static func ready(_ controller: PlayerController) async throws {
        for _ in 0..<160 {
            if let error = controller.error { throw TVError.message(error) }
            if controller.ready { return }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        throw TVError.message("TLS retry fixture did not become ready")
    }
    static func run(base: URL) async throws {
        let controller = PlayerController(), player = controller.player
        player.isMuted = true
        defer { controller.stop() }
        let episode = Episode(name: "TLS retry fixture", url: base.appendingPathComponent("test.mp4").absoluteString)
        let tls = NSError(domain: AVFoundationErrorDomain, code: AVError.unknown.rawValue, userInfo: [NSUnderlyingErrorKey: URLError(.secureConnectionFailed)])
        let protectedEpisode = Episode(name: "Header preservation fixture", url: episode.url + "?require-retry-header=1")
        controller.play(protectedEpisode, headers: ["X-Retry-Fixture": "preserved"])
        try await ready(controller)
        controller.setRate(1.25)
        await player.seek(to: CMTime(seconds: 4, preferredTimescale: 600))
        player.pause()
        let oldItem = player.currentItem!
        controller.handleFailure(tls, item: oldItem, fallback: nil, headers: [:])
        try require(!controller.ready && controller.error == nil && controller.connectingMessage.contains("1/1"), "First TLS failure must show retry progress, not an error")
        controller.handleFailure(tls, item: oldItem, fallback: nil, headers: [:])
        try await ready(controller)
        try await Task.sleep(nanoseconds: 200_000_000)
        let retryItem = player.currentItem!
        try require(retryItem !== oldItem && controller.player === player, "TLS retry must recreate the item, reusing the player")
        try require(player.rate == 0 && abs(player.currentTime().seconds - 4) < 0.3 && controller.rate == 1.25, "TLS retry lost pause, position or selected speed")
        controller.handleFailure(tls, item: retryItem, fallback: nil, headers: [:])
        try require(controller.failure?.kind == .tls && controller.error?.contains("已自动重试 1 次") == true, "Second TLS failure did not terminate with a Chinese explanation")
        try require(controller.error?.contains("A TLS error") == false && player.currentItem == nil, "Technical English escaped into the primary message")
        try await Task.sleep(nanoseconds: 900_000_000)
        try require(player.currentItem == nil && controller.error != nil, "TLS retry looped after the one retry budget")

        controller.play(episode, headers: [:], position: 1.2)
        controller.handleFailure(tls, item: player.currentItem!, fallback: nil, headers: [:])
        try await ready(controller)
        try await Task.sleep(nanoseconds: 200_000_000)
        try require(player.rate > 0 && player.currentTime().seconds >= 1, "TLS retry before initial readiness lost the resume position or autoplay")

        controller.play(episode, headers: [:]); try await ready(controller)
        controller.handleFailure(tls, item: player.currentItem!, fallback: nil, headers: [:])
        controller.stop()
        try await Task.sleep(nanoseconds: 900_000_000)
        try require(player.currentItem == nil && !controller.ready, "Stopping playback did not cancel the pending TLS retry")

        controller.play(episode, headers: [:]); try await ready(controller)
        let staleItem = player.currentItem!
        controller.handleFailure(tls, item: staleItem, fallback: nil, headers: [:])
        controller.play(episode, headers: [:]); try await ready(controller)
        let selectedItem = player.currentItem!
        controller.handleFailure(tls, item: staleItem, fallback: nil, headers: [:])
        try await Task.sleep(nanoseconds: 900_000_000)
        try require(player.currentItem === selectedItem && controller.error == nil, "An old TLS retry replaced the newly selected video")

        var routes: [Int] = []
        let secondRoute = Episode(name: "Second live route", url: episode.url + "?route=2")
        controller.playLive([episode, secondRoute], index: 0, headers: [:]) { routes.append($0) }
        try await ready(controller)
        controller.handleFailure(tls, item: player.currentItem!, fallback: episode, headers: [:])
        try require(routes == [0], "TLS retry advanced the live route before retrying")
        try await ready(controller)
        controller.handleFailure(tls, item: player.currentItem!, fallback: episode, headers: [:])
        for _ in 0..<100 {
            if routes == [0, 1] && controller.ready { break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        try require(routes == [0, 1] && controller.ready, "Failed TLS retry did not advance to the next live route")
        controller.handleFailure(tls, item: player.currentItem!, fallback: episode, headers: [:])
        try await ready(controller)
        controller.handleFailure(tls, item: player.currentItem!, fallback: episode, headers: [:])
        try require(controller.error?.contains("已尝试 2 条线路") == true && controller.error?.contains("已自动重试 1 次") == true, "Each live route must have an independent, bounded TLS retry")

        controller.play(episode, headers: [:]); try await ready(controller)
        let certificateItem = player.currentItem!
        controller.handleFailure(URLError(.serverCertificateUntrusted), item: certificateItem, fallback: nil, headers: [:])
        try require(controller.failure?.kind == .certificate && controller.error?.contains("已自动重试") == false, "Certificate failures must retain their specific explanation")
        print("PASS: one TLS retry, duplicate/stale error isolation, Chinese terminal message, headers/pause/position/rate retained, initial loading retry, stop/switch cancellation, per-live-route retry and certificate classification")
    }
}
