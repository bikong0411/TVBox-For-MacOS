import AppKit
import TVBoxCore

@main struct CheckDLNA {
    @MainActor static func require(_ value: @autoclosure () -> Bool, _ message: String) throws {
        if !value() { throw TVError.message(message) }
    }
    @MainActor static func wait(_ message: String, seconds: Double = 10, until: () -> Bool) async throws {
        for _ in 0..<Int(seconds*20) { if until() { return }; try await Task.sleep(nanoseconds: 50_000_000) }
        throw TVError.message(message)
    }
    @MainActor static func main() async {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let controller = PlayerController(), transport: PlaybackTransport
        transport = PlaybackTransport(controller: controller)
        defer { controller.stop() }
        do {
            let base = URL(string: CommandLine.arguments[1])!
            let inspection = URLSession(configuration: .ephemeral)
            defer { inspection.invalidateAndCancel() }
            func remote(_ key: String, equals expected: Int) async throws {
                for _ in 0..<100 {
                    let (data, _) = try await inspection.data(from: base.appendingPathComponent("state"))
                    let values = try JSONSerialization.jsonObject(with: data) as? [String: Any]
                    if (values?[key] as? NSNumber)?.intValue == expected { return }
                    try await Task.sleep(nanoseconds: 50_000_000)
                }
                throw TVError.message("Receiver did not acknowledge " + key)
            }
            let client = DLNAClient()
            let device = try await client.device(at: base.appendingPathComponent("device.xml"))
            try require(device.name == "测试 DLNA 电视" && device.transport.actions.contains("Seek"), "Device capabilities not parsed")
            controller.setVolume(0.12)
            let episode = Episode(name: "DLNA test", url: base.appendingPathComponent("test.mp4").absoluteString)
            controller.play(episode, headers: [:], position: 3)
            try await wait("Local playback failed") { controller.ready }
            try await wait("Local media not seekable or playing") { controller.canSeek && controller.playing }
            controller.cast(to: device)
            try await wait("DLNA connection failed: " + (controller.dlna.error ?? ""), seconds: 25) { controller.dlna.connected || controller.dlna.error != nil }
            try require(controller.dlna.connected, controller.dlna.error ?? "DLNA failed")
            try await wait("Local decoder was not paused") { controller.nativeSession?.playing == false }
            transport.refresh()
            try require(transport.playing && transport.canSeek && abs(transport.volume - 0.37) < 0.01, "TV state/volume was not read or Mac volume overwrote TV")
            transport.togglePlayback(rate: 1)
            try await wait("TV Pause failed") { !controller.dlna.state.playing && !controller.dlna.controlsBusy }
            transport.seek(to: 9)
            try await Task.sleep(nanoseconds: 600_000_000)
            try require(abs(controller.position - 9) < 0.1, "TV Seek failed")
            transport.setVolume(0.63); transport.toggleMute()
            try await remote("volume", equals: 63); try await remote("muted", equals: 1)
            try await wait("TV volume/mute failed") { !controller.dlna.controlsBusy && controller.dlna.state.muted == true && abs((controller.dlna.state.volume ?? 0)-0.63)<0.01 }
            controller.setRate(2)
            try require(controller.effectiveRate == 1, "DLNA displayed unsupported playback rate")
            controller.returnToLocal()
            try await remote("stops", equals: 1)
            try await wait("Local resume lost TV position") { abs(controller.position - 9) < 0.6 }
            try require(!controller.playing && controller.dlna.selectedDevice == nil && abs(controller.volume - 0.12) < 0.01, "Return lost pause or local volume")
            print("PASS: DLNA device XML, SOAP, TV fetch, pause, seek, volume, mute, real TV state, return position and Mac volume")

            var invalid = device; invalid.transport.controlURL = base.appendingPathComponent("missing")
            controller.togglePlayback(); controller.cast(to: invalid)
            try await wait("Failed connection never finished", seconds: 12) { controller.dlna.error != nil }
            try require(controller.playing, "Failed casting stopped local playback")
            controller.returnToLocal()
            let relay = CastMediaRelay(source: base.appendingPathComponent("extensionless"), headers: ["X-Cast-Fixture": "secret"], peer: "127.0.0.1")
            let relayURL = try await relay.start(); defer { relay.stop() }
            let config = URLSessionConfiguration.ephemeral; config.connectionProxyDictionary = [:]
            let session = URLSession(configuration: config); defer { session.invalidateAndCancel() }
            var head = URLRequest(url: relayURL); head.httpMethod = "HEAD"
            let (empty, hr) = try await session.data(for: head)
            try require(empty.isEmpty && (hr as? HTTPURLResponse)?.statusCode == 200, "Extensionless HLS HEAD failed")
            let (body, _) = try await session.data(from: relayURL)
            let manifest = String(decoding: body, as: UTF8.self)
            guard let target = manifest.components(separatedBy: .newlines).first(where: { $0.hasPrefix("http://") }), let url = URL(string: target) else { throw TVError.message("Manifest not rewritten") }
            let (segment, _) = try await session.data(from: url)
            try require(String(decoding: segment, as: UTF8.self) == "fixture-segment", "HLS custom headers were dropped")
            let redirect = CastMediaRelay(source: base.appendingPathComponent("redirect"), headers: ["X-Cast-Fixture": "secret"], peer: "127.0.0.1")
            let redirectURL = try await redirect.start(); defer { redirect.stop() }
            let (stripped, _) = try await session.data(from: redirectURL)
            try require(String(decoding: stripped, as: UTF8.self) == "stripped", "Cross-origin response unexpected: " + String(decoding: stripped, as: UTF8.self))
            print("PASS: failed cast keeps local playback; HTTP relay, extensionless HLS HEAD, segment authentication and cross-origin redirect")
            // Start/cancel/replace while a cast task is suspended must not pause the new decoder.
            controller.cast(to: device); controller.play(episode, headers: [:])
            try await wait("Replacement playback failed") { controller.ready }
            try await Task.sleep(nanoseconds: 800_000_000)
            try require(controller.playing && controller.dlna.selectedDevice == nil, "Old cast callback paused new playback")
            controller.stop(); try await Task.sleep(nanoseconds: 400_000_000)
            print("ALL DLNA CHECKS PASSED")
        } catch { fputs("FAIL: \(error.localizedDescription)\n", stderr); exit(1) }
    }
}
