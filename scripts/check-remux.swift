import Foundation
import AVFoundation

// Compile with Models.swift, LoopbackHLSServer.swift, LiveRemuxFailure.swift, and LiveRemuxSession.swift.
@main struct RemuxCheck {
    @MainActor static func main() async {
        guard CommandLine.arguments.count == 3, let input = URL(string: CommandLine.arguments[2]) else { print("Usage: check-remux HELPER INPUT_URL"); exit(2) }
        var session: LiveRemuxSession?
        do {
            let current = try LiveRemuxSession(helperURL: URL(fileURLWithPath: CommandLine.arguments[1])); session = current
            let url = try await current.start(input: input, headers: [:])
            let item = AVPlayerItem(url: url); item.preferredForwardBufferDuration = 3
            let player = AVPlayer(playerItem: item)
            for _ in 0..<300 {
                if item.status == .readyToPlay { break }
                if item.status == .failed { throw item.error ?? TVError.message("AVFoundation failed") }
                try await Task.sleep(nanoseconds: 100_000_000)
            }
            guard item.status == .readyToPlay else { throw TVError.message("AVFoundation readiness timeout") }
            player.play()
            let initial = player.currentTime().seconds
            for _ in 0..<100 {
                try await Task.sleep(nanoseconds: 100_000_000)
                if player.currentTime().seconds > initial + 0.5 { break }
                if let error = current.exitErrorIfFailed() { throw error }
            }
            let final = player.currentTime().seconds
            player.pause()
            guard final > initial + 0.5 else { throw TVError.message("Playback did not advance") }
            print("PASS: remuxed live input; AVFoundation ready; playback advanced from \(initial) to \(final)")
            current.stop()
            try await Task.sleep(nanoseconds: 500_000_000)
        } catch {
            session?.stop(); print("FAIL: \(String(reflecting: error))")
            try? await Task.sleep(nanoseconds: 500_000_000); exit(1)
        }
    }
}
