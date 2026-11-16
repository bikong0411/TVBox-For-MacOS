import Foundation
import Network

/// A per-cast, bounded streaming proxy. Only the chosen television may access
/// randomly mapped resources; clients cannot supply an arbitrary upstream URL.
public final class CastMediaRelay: @unchecked Sendable {
    private struct Resource { var url: URL; var touched: Date }
    private let queue = DispatchQueue(label: "TVBox.cast.relay")
    private let source: URL
    private let headers: [String: String]
    private let peer: String
    private let token = UUID().uuidString
    private let configuration = URLSessionConfiguration.ephemeral
    private var resources: [String: Resource] = [:]
    private var keys: [URL: String] = [:]
    private var rootKey = ""
    private var base: URL?
    private var listener: NWListener?
    private var stopped = false
    private var clients: [UUID: NWConnection] = [:]
    private var transfers: [UUID: RelayHTTPTransfer] = [:]
    public init(source: URL, headers: [String: String], peer: String) {
        self.source = source; self.headers = headers; self.peer = peer
        configuration.timeoutIntervalForRequest = 20; configuration.timeoutIntervalForResource = 24 * 3600
        configuration.urlCache = nil; configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
    }
    public func start() async throws -> URL {
        let route = try await Task.detached { try LANIPv4.route(to: self.peer) }.value
        try Task.checkCancellation()
        return try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do {
                    guard !self.stopped else { throw CancellationError() }
                    guard let host = IPv4Address(route.local) else { throw TVError.message("无法建立局域网投屏服务。") }
                    let parameters = NWParameters.tcp
                    parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(host), port: .any)
                    let listener = try NWListener(using: parameters); self.listener = listener
                    let gate = CastRelayStartGate(continuation)
                    listener.stateUpdateHandler = { [weak self, weak listener] state in
                        switch state {
                        case .ready:
                            guard let self, let port = listener?.port,
                                  let base = URL(string: "http://\(route.local):\(port.rawValue)/\(self.token)/") else {
                                gate.finish(.failure(TVError.message("投屏视频服务启动失败。"))); return
                            }
                            do {
                                self.base = base
                                let url = try self.register(self.source)
                                self.rootKey = url.lastPathComponent
                                gate.finish(.success(url))
                            } catch { gate.finish(.failure(error)) }
                        case .failed: gate.finish(.failure(TVError.message("无法启动投屏视频服务，请检查局域网权限。")))
                        case .cancelled: gate.finish(.failure(CancellationError()))
                        default: break
                        }
                    }
                    listener.newConnectionHandler = { [weak self] connection in
                        guard let self, self.clients.count < 16,
                              case .hostPort(let host, _) = connection.endpoint, String(describing: host) == self.peer else { connection.cancel(); return }
                        let id = UUID(); self.clients[id] = connection
                        connection.stateUpdateHandler = { [weak self, weak connection] state in
                            if case .failed = state { connection?.cancel() }
                            if case .cancelled = state {
                                self?.transfers.removeValue(forKey: id)?.cancel(); self?.clients.removeValue(forKey: id)
                            }
                        }
                        connection.start(queue: self.queue)
                        self.receive(connection, id: id, bytes: Data())
                        self.queue.asyncAfter(deadline: .now() + 10) { [weak self, weak connection] in
                            if self?.clients[id] != nil && self?.transfers[id] == nil { connection?.cancel() }
                        }
                    }
                    listener.start(queue: self.queue)
                } catch { continuation.resume(throwing: error) }
            }
        }
    }
    public func stop() {
        queue.async {
            self.stopped = true
            self.listener?.cancel(); self.listener = nil
            let clients = self.clients.values; self.clients.removeAll()
            self.transfers.values.forEach { $0.cancel() }; self.transfers.removeAll()
            clients.forEach { $0.cancel() }; self.resources.removeAll(); self.keys.removeAll(); self.base = nil
        }
    }
    deinit { listener?.cancel(); transfers.values.forEach { $0.cancel() }; clients.values.forEach { $0.cancel() } }
    public static func mime(_ url: URL) -> String {
        switch url.pathExtension.lowercased() {
        case "m3u8": return "application/vnd.apple.mpegurl"
        case "ts": return "video/mp2t"
        case "mkv": return "video/x-matroska"
        case "flv": return "video/x-flv"
        case "mp3": return "audio/mpeg"
        case "aac": return "audio/aac"
        case "m4s", "mp4", "m4v", "mov": return "video/mp4"
        default: return "application/octet-stream"
        }
    }
    public static func sameOrigin(_ a: URL, _ b: URL) -> Bool {
        a.scheme?.lowercased() == b.scheme?.lowercased() && a.host?.lowercased() == b.host?.lowercased()
            && (a.port ?? (a.scheme == "https" ? 443 : 80)) == (b.port ?? (b.scheme == "https" ? 443 : 80))
    }
    private func register(_ url: URL) throws -> URL {
        guard ["http", "https", "file"].contains(url.scheme?.lowercased() ?? ""), let base else { throw TVError.message("此视频地址暂不支持 DLNA 转发。") }
        if url.isFileURL {
            let directory = source.deletingLastPathComponent().resolvingSymlinksInPath().path + "/"
            guard source.isFileURL, url.resolvingSymlinksInPath().path.hasPrefix(directory) else { throw TVError.message("本地视频清单引用了目录以外的文件。") }
        }
        if let key = keys[url] { resources[key]?.touched = Date(); return base.appendingPathComponent(key) }
        if resources.count >= 2048, let old = resources.filter({ $0.key != rootKey }).min(by: { $0.value.touched < $1.value.touched }) {
            resources.removeValue(forKey: old.key); keys.removeValue(forKey: old.value.url)
        }
        let ext = url.pathExtension.lowercased()
        let suffix = ext.range(of: "^[a-z0-9]{1,8}$", options: .regularExpression) == nil ? "bin" : ext
        let key = UUID().uuidString + "." + suffix
        keys[url] = key; resources[key] = Resource(url: url, touched: Date())
        return base.appendingPathComponent(key)
    }
    private func rewrite(_ body: Data, from url: URL) throws -> Data {
        guard body.count <= 2 * 1024 * 1024, let text = String(data: body, encoding: .utf8), text.hasPrefix("#EXTM3U") else { throw TVError.message("片源没有返回有效的视频清单。") }
        let expression = try NSRegularExpression(pattern: #"URI="([^"]+)""#)
        let lines = try text.components(separatedBy: .newlines).map { line -> String in
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { return line }
            if !trimmed.hasPrefix("#") {
                guard let resource = URL(string: trimmed, relativeTo: url)?.absoluteURL else { throw TVError.message("视频分段地址无效。") }
                return try register(resource).absoluteString
            }
            var rewritten = line
            for match in expression.matches(in: line, range: NSRange(line.startIndex..., in: line)).reversed() {
                guard let range = Range(match.range(at: 1), in: line),
                      let resource = URL(string: String(line[range]), relativeTo: url)?.absoluteURL,
                      ["http", "https", "file"].contains(resource.scheme?.lowercased() ?? "") else { continue }
                let target = try register(resource).absoluteString
                guard let replace = Range(match.range(at: 1), in: rewritten) else { continue }
                rewritten.replaceSubrange(replace, with: target)
            }
            return rewritten
        }
        return Data(lines.joined(separator: "\n").utf8)
    }
    private func receive(_ connection: NWConnection, id: UUID, bytes: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [weak self] data, _, complete, error in
            guard let self else { connection.cancel(); return }
            var received = bytes; if let data { received.append(data) }
            guard received.count <= 16_384 else { self.sendError(400, connection); return }
            guard received.range(of: Data("\r\n\r\n".utf8)) != nil else {
                if complete || error != nil { connection.cancel() } else { self.receive(connection, id: id, bytes: received) }; return
            }
            guard let request = String(data: received, encoding: .utf8) else { self.sendError(400, connection); return }
            let lines = request.components(separatedBy: "\r\n")
            let parts = (lines.first ?? "").split(separator: " ")
            guard parts.count == 3, ["GET", "HEAD"].contains(String(parts[0])) else { self.sendError(405, connection); return }
            let path = String(parts[1]).components(separatedBy: "?")[0]
            let components = path.split(separator: "/", omittingEmptySubsequences: false)
            guard components.count == 3, components[0].isEmpty, components[1] == self.token,
                  let resource = self.resources[String(components[2])] else { self.sendError(404, connection); return }
            self.resources[String(components[2])]?.touched = Date()
            let method = String(parts[0])
            let range = lines.first { $0.lowercased().hasPrefix("range:") }.map { String($0.dropFirst(6)).trimmingCharacters(in: .whitespaces) }
            if resource.url.isFileURL {
                self.serveFile(resource.url, method: method, range: range, connection: connection); return
            }
            var upstream = URLRequest(url: resource.url)
            let hls = resource.url.pathExtension.lowercased() == "m3u8"
            // Fetch metadata-only HEAD requests with GET as extensionless HLS
            // endpoints must still be rewritten and measured for the receiver.
            upstream.httpMethod = "GET"
            if !hls, let range { upstream.setValue(range, forHTTPHeaderField: "Range") }
            for (key, value) in self.headers {
                if Self.sameOrigin(resource.url, self.source) || ["user-agent", "referer"].contains(key.lowercased()) {
                    upstream.setValue(value, forHTTPHeaderField: key)
                }
            }
            let transfer = RelayHTTPTransfer(connection: connection, queue: self.queue, configuration: self.configuration, request: upstream,
                                             head: method == "HEAD", hls: hls,
                                             rewrite: { [weak self] body, finalURL in guard let self else { throw CancellationError() }; return try self.rewrite(body, from: finalURL) })
            self.transfers[id] = transfer; transfer.start()
        }
    }
    private func serveFile(_ url: URL, method: String, range: String?, connection: NWConnection) {
        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            guard attributes[.type] as? FileAttributeType == .typeRegular, let size = (attributes[.size] as? NSNumber)?.int64Value else { sendError(404, connection); return }
            if url.pathExtension.lowercased() == "m3u8" {
                guard size <= 2 * 1024 * 1024 else { sendError(502, connection); return }
                let data = try rewrite(Data(contentsOf: url), from: url)
                sendHeader(200, headers: ["Content-Type": Self.mime(url), "Content-Length": "\(data.count)"], connection: connection)
                connection.send(content: method == "HEAD" ? Data() : data, completion: .contentProcessed { _ in connection.cancel() }); return
            }
            guard let bounds = Self.byteRange(range, size: size) else {
                sendHeader(416, headers: ["Content-Length": "0", "Content-Range": "bytes */\(size)"], connection: connection); connection.send(content: Data(), completion: .contentProcessed { _ in connection.cancel() }); return
            }
            let length = bounds.upperBound - bounds.lowerBound
            var headers = ["Content-Type": Self.mime(url), "Content-Length": "\(length)", "Accept-Ranges": "bytes"]
            if range != nil { headers["Content-Range"] = "bytes \(bounds.lowerBound)-\(bounds.upperBound - 1)/\(size)" }
            let handle = try FileHandle(forReadingFrom: url)
            try handle.seek(toOffset: UInt64(bounds.lowerBound))
            sendHeader(range == nil ? 200 : 206, headers: headers, connection: connection)
            if method == "HEAD" { try? handle.close(); connection.send(content: Data(), completion: .contentProcessed { _ in connection.cancel() }); return }
            sendFileChunk(handle, remaining: length, connection: connection)
        } catch { sendError(502, connection) }
    }
    private func sendFileChunk(_ handle: FileHandle, remaining: Int64, connection: NWConnection) {
        guard remaining > 0 else { try? handle.close(); connection.cancel(); return }
        do {
            guard let data = try handle.read(upToCount: Int(min(65_536, remaining))), !data.isEmpty else { try? handle.close(); connection.cancel(); return }
            connection.send(content: data, completion: .contentProcessed { [weak self] error in
                self?.queue.async {
                    if error != nil { try? handle.close(); connection.cancel() }
                    else { self?.sendFileChunk(handle, remaining: remaining - Int64(data.count), connection: connection) }
                }
            })
        } catch { try? handle.close(); connection.cancel() }
    }
    public static func byteRange(_ range: String?, size: Int64) -> Range<Int64>? {
        guard size >= 0 else { return nil }
        guard let range else { return 0..<size }
        guard range.hasPrefix("bytes="), !range.contains(",") else { return nil }
        let parts = range.dropFirst(6).split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2, size > 0 else { return nil }
        if parts[0].isEmpty {
            guard let tail = Int64(parts[1]), tail > 0 else { return nil }; return max(0, size - tail)..<size
        }
        guard let start = Int64(parts[0]), start >= 0, start < size else { return nil }
        let end = parts[1].isEmpty ? size - 1 : (Int64(parts[1]) ?? -1)
        guard end >= start else { return nil }; return start..<(min(end, size - 1) + 1)
    }
    private func sendHeader(_ status: Int, headers: [String: String], connection: NWConnection) {
        connection.send(content: Self.responseHeader(status, headers), completion: .contentProcessed { _ in })
    }
    private func sendError(_ status: Int, _ connection: NWConnection) {
        connection.send(content: Self.responseHeader(status, ["Content-Length": "0"]), completion: .contentProcessed { _ in connection.cancel() })
    }
    fileprivate static func responseHeader(_ status: Int, _ headers: [String: String]) -> Data {
        var text = "HTTP/1.1 \(status) \(status == 200 ? "OK" : status == 206 ? "Partial Content" : "Response")\r\n"
        for (key, value) in headers where !value.contains("\r") && !value.contains("\n") { text += "\(key): \(value)\r\n" }
        text += "Connection: close\r\nCache-Control: no-store\r\ntransferMode.dlna.org: Streaming\r\n\r\n"
        return Data(text.utf8)
    }
}

private final class RelayHTTPTransfer: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let connection: NWConnection
    private let queue: DispatchQueue
    private let configuration: URLSessionConfiguration
    private let request: URLRequest
    private let head: Bool
    private var hls: Bool
    private let rewrite: (Data, URL) throws -> Data
    private var session: URLSession?
    private var task: URLSessionDataTask?
    private var response: HTTPURLResponse?
    private var pending: [Data] = []
    private var pendingSize = 0
    private var sending = false
    private var suspended = false
    private var completed = false
    private var cancelled = false
    private var chunked = false
    private var manifest = Data()
    init(connection: NWConnection, queue: DispatchQueue, configuration: URLSessionConfiguration, request: URLRequest,
         head: Bool, hls: Bool, rewrite: @escaping (Data, URL) throws -> Data) {
        self.connection = connection; self.queue = queue; self.configuration = configuration; self.request = request
        self.head = head; self.hls = hls; self.rewrite = rewrite
    }
    func start() {
        let operations = OperationQueue(); operations.maxConcurrentOperationCount = 1; operations.underlyingQueue = queue
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: operations)
        self.session = session
        task = session.dataTask(with: request); task?.resume()
    }
    func cancel() { cancelled = true; task?.cancel(); session?.invalidateAndCancel(); session = nil }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        var redirected = request
        if let previous = response.url, let target = request.url, !CastMediaRelay.sameOrigin(previous, target) {
            // A fresh request also drops CFNetwork's inherited redirect headers.
            redirected = URLRequest(url: target, cachePolicy: request.cachePolicy, timeoutInterval: request.timeoutInterval)
            redirected.httpMethod = request.httpMethod
            redirected.allHTTPHeaderFields = request.allHTTPHeaderFields?.filter {
                ["user-agent", "referer", "range", "accept"].contains($0.key.lowercased())
            }
        }
        completionHandler(redirected)
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse, completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard !cancelled, let response = response as? HTTPURLResponse else { completionHandler(.cancel); return }
        self.response = response
        hls = hls || (response.mimeType?.lowercased().contains("mpegurl") == true)
        if hls {
            guard response.expectedContentLength <= 2 * 1024 * 1024 else { completionHandler(.cancel); connection.cancel(); return }
        } else {
            var headers = ["Content-Type": response.value(forHTTPHeaderField: "Content-Type") ?? CastMediaRelay.mime(request.url!)]
            for name in ["Content-Length", "Content-Range", "Accept-Ranges"] {
                if let value = response.value(forHTTPHeaderField: name) { headers[name] = value }
            }
            if headers["Content-Length"] == nil && !head { chunked = true; headers["Transfer-Encoding"] = "chunked" }
            enqueue(CastMediaRelay.responseHeader(response.statusCode, headers))
            if head { completed = true; completionHandler(.cancel); drain(); return }
        }
        completionHandler(.allow)
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard !cancelled else { return }
        if hls {
            guard manifest.count + data.count <= 2 * 1024 * 1024 else { cancel(); connection.cancel(); return }
            manifest.append(data)
        } else if !head {
            if chunked {
                var chunk = Data("\(String(data.count, radix: 16))\r\n".utf8); chunk.append(data); chunk.append(Data("\r\n".utf8)); enqueue(chunk)
            } else { enqueue(data) }
        }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard !cancelled else { return }
        defer { session.finishTasksAndInvalidate(); self.session = nil }
        if head && !hls && response != nil { return }
        if let _ = error {
            if response == nil { enqueue(CastMediaRelay.responseHeader(502, ["Content-Length": "0"])) }
            completed = true; drain(); return
        }
        if hls {
            do {
                guard let response, (200..<300).contains(response.statusCode) else { throw TVError.message("片源响应异常。") }
                let data = try rewrite(manifest, response.url ?? request.url!)
                enqueue(CastMediaRelay.responseHeader(200, ["Content-Type": "application/vnd.apple.mpegurl", "Content-Length": "\(data.count)"]))
                if !head { enqueue(data) }
            } catch { enqueue(CastMediaRelay.responseHeader(502, ["Content-Length": "0"])) }
        } else if chunked { enqueue(Data("0\r\n\r\n".utf8)) }
        completed = true; drain()
    }
    private func enqueue(_ data: Data) {
        pending.append(data); pendingSize += data.count
        if pendingSize > 512 * 1024 && !suspended && !completed { task?.suspend(); suspended = true }
        drain()
    }
    private func drain() {
        guard !cancelled, !sending else { return }
        guard !pending.isEmpty else { if completed { connection.cancel() }; return }
        let data = pending.removeFirst(); pendingSize -= data.count; sending = true
        if suspended && pendingSize < 128 * 1024 { task?.resume(); suspended = false }
        connection.send(content: data, completion: .contentProcessed { [weak self] error in
            guard let self else { return }
            self.queue.async {
                self.sending = false
                if error != nil { self.cancel(); self.connection.cancel() } else { self.drain() }
            }
        })
    }
}

private final class CastRelayStartGate: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<URL, Error>?
    init(_ continuation: CheckedContinuation<URL, Error>) { self.continuation = continuation }
    func finish(_ result: Result<URL, Error>) { lock.lock(); let pending = continuation; continuation = nil; lock.unlock(); pending?.resume(with: result) }
}
