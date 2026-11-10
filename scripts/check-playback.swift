import Foundation
import AVFoundation

// Native AVFoundation probe, independent of the app's saved configuration.
@main struct PlaybackCheck {
    @MainActor static func main() async {
        guard CommandLine.arguments.count == 2, let url = URL(string: CommandLine.arguments[1]) else {
            print("Usage: check-playback URL"); exit(2)
        }
        let item = AVPlayerItem(url: url)
        let player = AVPlayer(playerItem: item)
        do {
            for _ in 0..<200 {
                if item.status == .readyToPlay { break }
                if item.status == .failed { throw item.error ?? NSError(domain: "PlaybackCheck", code: 1) }
                try await Task.sleep(nanoseconds: 100_000_000)
            }
            guard item.status == .readyToPlay else { throw NSError(domain: "PlaybackCheck", code: 2, userInfo: [NSLocalizedDescriptionKey: "Readiness timeout"]) }
            let seeked = await player.seek(to: CMTime(seconds: 5, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
            guard seeked else { throw NSError(domain: "PlaybackCheck", code: 3, userInfo: [NSLocalizedDescriptionKey: "Seek failed"]) }
            player.play()
            for _ in 0..<50 {
                try await Task.sleep(nanoseconds: 100_000_000)
                if player.currentTime().seconds > 5.3 { break }
            }
            let position = player.currentTime().seconds
            player.pause()
            guard position > 5.3 else { throw NSError(domain: "PlaybackCheck", code: 4, userInfo: [NSLocalizedDescriptionKey: "Playback did not advance"]) }
            print("PASS: AVFoundation loaded video, sought to 5s, and played to \(String(format: "%.2f", position))s. Duration: \(item.duration.seconds)s")
        } catch {
            print("FAIL: \(String(reflecting: error))"); exit(1)
        }
    }
}
