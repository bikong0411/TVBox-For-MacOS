import AppKit
import TVBoxCore

@main struct CheckAirPlayVideo {
    @MainActor static var controller: PlayerController?
    @MainActor static func serviceRunLoop() { _ = RunLoop.current.run(mode: .default, before: Date()) }
    @MainActor static func require(_ value: @autoclosure () -> Bool, _ message: String) throws { if !value() { throw TVError.message(message) } }
    @MainActor static func wait(_ message: String, seconds: Double = 12, until: () -> Bool) async throws {
        for _ in 0..<Int(seconds * 20) {
            serviceRunLoop()
            if let v = controller?.mpvSession?.renderingView { v.draw(v.bounds) }
            if until() { return }; try await Task.sleep(nanoseconds: 50_000_000)
        }
        throw TVError.message(message + "; " + (controller?.dlna.error ?? ""))
    }
    @MainActor static func main() async {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let player = PlayerController(); controller = player; player.preferMPV = true; player.setVolume(0.12); player.toggleMute()
        let window = NSWindow(contentRect: NSRect(x: 0,y: 0,width: 640,height: 360),styleMask: .borderless,backing: .buffered,defer: false); window.isReleasedWhenClosed = false
        let host = VideoHostView(surface: player.videoSurface); window.contentView = host; player.videoSurface.attach(to: host)
        defer { player.stop(); window.contentView = nil; window.close() }
        do {
            if CommandLine.arguments.contains("--real-device") { try await realReceiver(player); return }
            let endpoints = CommandLine.arguments.dropFirst().map { URL(string: $0)! }
            let base = endpoints[0]
            let inspection = URLSession(configuration: .ephemeral)
            func stats() async throws -> [String: Any] {
                let (data, _) = try await inspection.data(from: base.appendingPathComponent("state"))
                return try JSONSerialization.jsonObject(with: data) as! [String: Any]
            }
            func device(_ endpoint: URL) throws -> DLNADevice {
                try AirPlayVideoProtocol.device(name: "AirPlay fixture", id: endpoint.absoluteString, address: endpoint.host!, port: endpoint.port!, features: "0x527FFFF7,0x1E", passwordRequired: false)
            }
            let episode = Episode(name: "Authenticated fixture", url: base.appendingPathComponent("source.mp4").absoluteString)
            player.play(episode, headers: ["X-AirPlay-Fixture": "preserved"], position: 3)
            try await wait("Native input did not start") { player.ready && player.position > 3.2 }
            player.setRate(1.25); let native = player.mpvSession
            player.cast(to: try device(base))
            try await wait("AirPlay compatibility did not start") { player.dlna.connected || player.dlna.error != nil }
            try require(player.dlna.connected && player.dlna.selectedDevice?.isAirPlayVideo == true, "Remote did not use AirPlay video")
            try await wait("Native decoder was not paused") { native?.playing == false }
            try require(player.mpvSession === native && !player.systemPlayback && !player.canVolume && !player.canMute && player.effectiveRate == 1, "Casting changed decoder or invented remote controls")
            player.pause(); try await wait("AirPlay pause failed") { !player.playing && !player.dlna.controlsBusy }
            player.seek(to: 9); try await wait("AirPlay scrub failed") { abs(player.position - 9) < 0.1 && !player.dlna.controlsBusy }
            player.returnToLocal()
            try await wait("Native return lost progress") { abs(player.position - 9) < 0.8 }
            try require(player.mpvSession === native && !player.playing && player.volume == 0.12 && player.effectiveRate == 1.25, "Native return lost pause/rate/volume")
            print("PASS: production native decoder → AirPlay video relay, custom auth, real receiver Range fetch, pause/scrub, disabled volume, native return")

            player.togglePlayback(); player.cast(to: try device(base))
            try await wait("Second AirPlay cast failed") { player.dlna.connected }
            player.togglePlayback(); try await wait("Second cast pause failed") { !player.playing && !player.dlna.controlsBusy }
            player.togglePlayback(); try await wait("AirPlay resume failed") { player.playing && !player.dlna.controlsBusy }
            player.play(episode, headers: ["X-AirPlay-Fixture": "preserved"])
            try await wait("Changing episodes did not recast") { player.ready && player.dlna.connected }
            player.returnToLocal()
            print("PASS: recast, play/pause controls and automatic episode handoff retain selected AirPlay receiver")

            player.cast(to: try device(endpoints[1]))
            try await wait("Unauthorized receiver never failed") { player.dlna.error != nil }
            try require(player.dlna.error?.contains("授权") == true && player.playing && !player.dlna.connected, "Unauthorized receiver was bypassed or stopped local playback")
            player.returnToLocal()
            player.cast(to: try device(endpoints[2]))
            try await wait("Redirected control never failed") { player.dlna.error != nil }
            try require(!player.dlna.connected && player.playing, "Redirect failure stopped native playback")
            player.returnToLocal()
            print("PASS: 401 refusal is explicit, no retry/downgrade; control redirects cannot leak the media address")

            let before = try await stats()["plays"] as! Int
            player.cast(to: try device(endpoints[3]))
            try await Task.sleep(nanoseconds: 300_000_000)
            player.returnToLocal()
            try await Task.sleep(nanoseconds: 1_500_000_000)
            let after = try await stats()
            try require((after["plays"] as! Int) > before && after["ready"] as? Bool == false && (after["events"] as! [String]).last == "stop", "A late accepted Play escaped cancellation Stop")
            try require(player.playing && player.dlna.selectedDevice == nil && player.error == nil, "Cancelled cast changed local playback")
            print("PASS: cancellation waits for late Play acknowledgment and sends Stop after it; local decoder keeps playing")
            player.stop(); try await Task.sleep(nanoseconds: 300_000_000)
            print("ALL AIRPLAY VIDEO CHECKS PASSED")
        } catch { await player.dlna.disconnect().value; fputs("FAIL: \(error.localizedDescription)\n",stderr); exit(1) }
    }
    @MainActor static func realReceiver(_ player: PlayerController) async throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let values = try JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent(".build/airplay-device-private.json"))) as! [String: Any]
        let name = values["name"] as! String, address = values["address"] as! String
        player.dlna.searchAirPlay()
        try await wait("Production Bonjour did not find the selected receiver") { player.dlna.airPlayDevices.contains { $0.name == name && $0.transport.controlURL.host == address } }
        let device = player.dlna.airPlayDevices.first { $0.name == name && $0.transport.controlURL.host == address }!
        let api = AirPlayVideoClient()
        let before = try await api.state(on: device.transport.controlURL)
        try require(!before.ready || before.rate == 0, "Receiver is already playing; no test started")
        player.play(Episode(name: "Silent production AirPlay test", url: root.appendingPathComponent(".build/airplay-controller-test.mp4").absoluteString), headers: [:])
        try await wait("Native test video did not start") { player.ready && player.position > 0.2 }
        let native = player.mpvSession
        player.cast(to: device)
        try await wait("Production AirPlay did not start", seconds: 25) { player.dlna.connected || player.dlna.error != nil }
        try require(player.dlna.connected && native?.playing == false, player.dlna.error ?? "Receiver never confirmed playback")
        try await wait("Real receiver clock did not advance") { player.position >= 1 }
        print("REAL-TV PASS: production Bonjour + relay + AirPlay playback; receiver clock", player.position); fflush(stdout)
        player.pause(); try await wait("Real receiver pause failed") { !player.playing && !player.dlna.controlsBusy }
        player.seek(to: 8); try await wait("Real receiver seek failed") { abs(player.position - 8) < 1.5 && !player.dlna.controlsBusy }
        player.togglePlayback(); try await wait("Real receiver resume failed") { player.playing && player.position >= 9 }
        let resume = player.position
        player.returnToLocal(); await player.dlna.disconnect().value
        try await wait("Returning from real TV lost the native decoder") { player.mpvSession === native && player.playing && player.position >= resume - 1.5 }
        let stopped = try await api.state(on: device.transport.controlURL)
        try require(!stopped.ready || stopped.rate == 0, "Real receiver did not stop")
        try require(player.muted && player.volume == 0.12, "Local mute/volume were changed")
        print("REAL-TV PASS: pause, seek, resume, Stop acknowledged and native playback restored"); fflush(stdout)
    }
}
