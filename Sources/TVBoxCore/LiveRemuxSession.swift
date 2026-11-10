import Foundation

/// One helper process and bounded HLS cache per playing live channel.
@MainActor public final class LiveRemuxSession {
    private let helperURL: URL
    private let directory: URL
    private let server: LoopbackHLSServer
    private let process = Process()
    private var logHandle: FileHandle?
    private var started = false
    private var stopped = false
    public var isRunning: Bool { started && process.isRunning }

    public init(helperURL: URL) throws {
        guard FileManager.default.isExecutableFile(atPath: helperURL.path) else { throw TVError.message("直播兼容组件缺失，请使用完整的 App 发布包。") }
        self.helperURL = helperURL
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("tvbox-live-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        server = LoopbackHLSServer(directory: directory)
    }
    public static var bundledHelperURL: URL { Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/tvbox-remux") }

    public func start(input: URL, headers: [String: String]) async throws -> URL {
        guard !started, !stopped else { throw CancellationError() }
        let localURL = try await server.start()
        try Task.checkCancellation()
        let output = directory.appendingPathComponent("index.m3u8")
        let log = directory.appendingPathComponent("error.log")
        _ = FileManager.default.createFile(atPath: log.path, contents: nil, attributes: [.posixPermissions: 0o600])
        logHandle = try FileHandle(forWritingTo: log)
        var safeHeaders = headers.filter { !$0.key.contains("\r") && !$0.key.contains("\n") && !$0.value.contains("\r") && !$0.value.contains("\n") }
        if !safeHeaders.keys.contains(where: { $0.lowercased() == "user-agent" }) { safeHeaders["User-Agent"] = "TVBoxMac/0.3" }
        let rawHeaders = safeHeaders.sorted { $0.key < $1.key }.map { "\($0.key): \($0.value)\r\n" }.joined()
        process.executableURL = helperURL
        process.arguments = [input.absoluteString, output.path, rawHeaders]
        process.standardInput = FileHandle.nullDevice; process.standardOutput = FileHandle.nullDevice; process.standardError = logHandle
        try process.run(); started = true
        for _ in 0..<450 {
            try Task.checkCancellation()
            if stopped { throw CancellationError() }
            if let manifest = try? String(contentsOf: output, encoding: .utf8), manifest.contains("#EXTINF:") { return localURL }
            if !process.isRunning { throw helperError(log) }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        throw LiveRemuxFailure(timeout: true)
    }
    public func exitErrorIfFailed() -> Error? {
        guard started, !process.isRunning, process.terminationStatus != 0, !stopped else { return nil }
        return helperError(directory.appendingPathComponent("error.log"))
    }
    private func helperError(_ log: URL) -> Error {
        let details = (try? String(contentsOf: log, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return LiveRemuxFailure(log: details)
    }
    public func stop() {
        guard !stopped else { return }; stopped = true
        Self.cleanup(server: server, process: process, directory: directory, handle: logHandle, started: started)
        logHandle = nil
    }
    private nonisolated static func cleanup(server: LoopbackHLSServer, process: Process, directory: URL, handle: FileHandle?, started: Bool) {
        server.stop()
        let running = started && process.isRunning
        if running { process.terminate() }
        DispatchQueue.global(qos: .utility).async {
            if running { process.waitUntilExit() }
            try? handle?.close()
            try? FileManager.default.removeItem(at: directory)
        }
    }
    deinit { if !stopped { Self.cleanup(server: server, process: process, directory: directory, handle: logHandle, started: started) } }
}
