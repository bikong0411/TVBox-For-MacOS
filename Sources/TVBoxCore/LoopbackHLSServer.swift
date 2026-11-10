import Foundation
import Network

public struct LocalMediaResponse {
    public var status: Int
    public var headers: [String: String]
    public var body: Data
}

/// Serves a single remux session, bound only to 127.0.0.1 with an unguessable path.
public final class LoopbackHLSServer: @unchecked Sendable {
    private let directory: URL
    public let token: String
    private let queue = DispatchQueue(label: "local.tvboxmac.hls")
    private var listener: NWListener?
    private var connections: [UUID: NWConnection] = [:]
    public init(directory: URL, token: String = UUID().uuidString) { self.directory = directory; self.token = token }

    public func start() async throws -> URL {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        let listener = try NWListener(using: parameters)
        self.listener = listener
        return try await withCheckedThrowingContinuation { continuation in
            let gate = ListenerGate(continuation)
            listener.stateUpdateHandler = { [weak self, weak listener] state in
                switch state {
                case .ready:
                    guard let self, let port = listener?.port,
                          let url = URL(string: "http://127.0.0.1:\(port.rawValue)/\(self.token)/index.m3u8") else {
                        gate.finish(.failure(TVError.message("无法启动本机直播服务。"))); return
                    }
                    gate.finish(.success(url))
                case .failed(let error): gate.finish(.failure(error))
                case .cancelled: gate.finish(.failure(CancellationError()))
                default: break
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                guard let self else { connection.cancel(); return }
                let id = UUID(); self.connections[id] = connection
                connection.stateUpdateHandler = { [weak self, weak connection] state in
                    if case .cancelled = state { self?.connections.removeValue(forKey: id) }
                    if case .failed = state { connection?.cancel() }
                }
                connection.start(queue: self.queue)
                self.receive(connection, accumulated: Data())
            }
            listener.start(queue: queue)
        }
    }
    public func stop() {
        listener?.cancel()
        queue.async { [weak self] in
            guard let self else { return }
            let current = Array(self.connections.values); self.connections.removeAll()
            current.forEach { $0.cancel() }
        }
    }
    deinit { listener?.cancel(); connections.values.forEach { $0.cancel() } }

    private func receive(_ connection: NWConnection, accumulated: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [weak self] data, _, complete, error in
            guard let self else { connection.cancel(); return }
            var bytes = accumulated; if let data { bytes.append(data) }
            if bytes.count > 16_384 { connection.cancel(); return }
            if bytes.range(of: Data("\r\n\r\n".utf8)) != nil {
                let response = Self.response(for: bytes, directory: self.directory, token: self.token)
                var header = "HTTP/1.1 \(response.status) \(Self.reason(response.status))\r\n"
                response.headers.sorted { $0.key < $1.key }.forEach { header += "\($0.key): \($0.value)\r\n" }
                header += "Connection: close\r\nCache-Control: no-store\r\n\r\n"
                var output = Data(header.utf8); output.append(response.body)
                connection.send(content: output, completion: .contentProcessed { _ in connection.cancel() })
            } else if complete || error != nil { connection.cancel() }
            else { self.receive(connection, accumulated: bytes) }
        }
    }

    /// Kept separate from the socket implementation to test range and path handling.
    public static func response(for request: Data, directory: URL, token: String) -> LocalMediaResponse {
        func empty(_ status: Int) -> LocalMediaResponse { LocalMediaResponse(status: status, headers: ["Content-Length": "0"], body: Data()) }
        guard let text = String(data: request, encoding: .utf8) else { return empty(400) }
        let lines = text.components(separatedBy: "\r\n")
        let parts = (lines.first ?? "").split(separator: " ")
        guard parts.count == 3 else { return empty(400) }
        let method = String(parts[0]); guard ["GET", "HEAD"].contains(method) else { return empty(405) }
        let path = String(parts[1]).components(separatedBy: "?")[0]
        guard let decoded = path.removingPercentEncoding else { return empty(400) }
        let components = decoded.split(separator: "/", omittingEmptySubsequences: false)
        guard components.count == 3, components[0].isEmpty, components[1] == token else { return empty(404) }
        let filename = String(components[2])
        guard filename.range(of: "^[A-Za-z0-9_-]+\\.(m3u8|ts)$", options: .regularExpression) != nil else { return empty(404) }
        let file = directory.appendingPathComponent(filename)
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: file.path),
              attributes[.type] as? FileAttributeType == .typeRegular,
              let length = attributes[.size] as? NSNumber, length.intValue <= 64 * 1024 * 1024,
              let data = try? Data(contentsOf: file) else { return empty(404) }
        var headers = ["Content-Type": filename.hasSuffix(".m3u8") ? "application/vnd.apple.mpegurl" : "video/mp2t", "Accept-Ranges": "bytes"]
        let rangeValue = lines.dropFirst().first { $0.lowercased().hasPrefix("range:") }?.dropFirst(6).trimmingCharacters(in: .whitespaces)
        var body = data; var status = 200
        if let rangeValue {
            guard let range = byteRange(rangeValue, length: data.count) else {
                return LocalMediaResponse(status: 416, headers: ["Content-Length": "0", "Content-Range": "bytes */\(data.count)"], body: Data())
            }
            status = 206; body = data.subdata(in: range)
            headers["Content-Range"] = "bytes \(range.lowerBound)-\(range.upperBound - 1)/\(data.count)"
        }
        headers["Content-Length"] = String(body.count)
        return LocalMediaResponse(status: status, headers: headers, body: method == "HEAD" ? Data() : body)
    }
    private static func byteRange(_ header: String, length: Int) -> Range<Int>? {
        guard header.hasPrefix("bytes="), length > 0 else { return nil }
        let parts = header.dropFirst(6).split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2 else { return nil }
        if parts[0].isEmpty {
            guard let suffix = Int(parts[1]), suffix > 0 else { return nil }; return max(0, length - suffix)..<length
        }
        guard let start = Int(parts[0]), start >= 0, start < length else { return nil }
        let end = parts[1].isEmpty ? length - 1 : (Int(parts[1]) ?? -1)
        guard end >= start else { return nil }
        return start..<(min(end, length - 1) + 1)
    }
    private static func reason(_ code: Int) -> String {
        switch code { case 200: return "OK"; case 206: return "Partial Content"; case 400: return "Bad Request"; case 405: return "Method Not Allowed"; case 416: return "Range Not Satisfiable"; default: return "Not Found" }
    }
}

private final class ListenerGate: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<URL, Error>?
    init(_ continuation: CheckedContinuation<URL, Error>) { self.continuation = continuation }
    func finish(_ result: Result<URL, Error>) {
        lock.lock(); let current = continuation; continuation = nil; lock.unlock()
        current?.resume(with: result)
    }
}
