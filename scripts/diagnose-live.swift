import Foundation

// Read-only investigation; writes only the selected channel into a private temp file.
@main struct LiveDiagnostic {
    static func main() async {
        guard CommandLine.arguments.count == 4 else { print("Usage: diagnose-live SOURCE_JSON CHANNEL_NAME OUTPUT_JSON"); exit(2) }
        do { try await run() }
        catch { let error = error as NSError; print("Diagnostic failed: \(error.domain) (\(error.code))"); exit(1) }
    }
    static func run() async throws {
        let source = try JSONDecoder().decode(SavedLiveSource.self, from: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1])))
        var channels = source.channels
        for feed in source.feeds { channels += try await TVService().channels(feed: feed) }
        let index = ChannelIndex(channels: channels)
        guard let channel = index.channels.first(where: { $0.name == CommandLine.arguments[2] }) else { throw TVError.message("Channel not found") }
        let output = URL(fileURLWithPath: CommandLine.arguments[3])
        try JSONEncoder().encode(channel).write(to: output, options: [.atomic])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: output.path)
        print("Found \(channel.name); \(channel.urls.count) routes; headers \(channel.headers.keys.sorted())")
    }
}
