import Foundation
import CryptoKit

public struct CSPWorkerConnection: Sendable {
    public let endpoint: URL
    public let token: String
    public init(endpoint: URL, token: String) throws {
        guard endpoint.scheme == "http", endpoint.host == "127.0.0.1", endpoint.port != nil,
              endpoint.user == nil, endpoint.password == nil, endpoint.query == nil, endpoint.fragment == nil,
              endpoint.path.isEmpty || endpoint.path == "/",
              token.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil else {
            throw TVError.message("爬虫运行组件连接信息无效。")
        }
        self.endpoint = endpoint; self.token = token
    }
}

public protocol CSPRuntimeProvider: Sendable {
    func connection(componentHash: String) async throws -> CSPWorkerConnection
}

final class CSPNoRedirect: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

private enum CSPWorkerFailure: LocalizedError {
    case sessionMissing
    var errorDescription: String? { "爬虫运行组件已重启，请重试当前接口。" }
}

/// The Mac downloads a component as data; only the Android worker loads it.
public actor CSPRPCTransport: CSPTransport {
    private let runtime: any CSPRuntimeProvider
    private let upstream: URLSession
    private let local: URLSession
    private let callTimeout: TimeInterval
    private var components: [CSPComponent: Task<Data, Error>] = [:]
    private var loads: [String: Task<Void, Error>] = [:]
    private var calls: [String: Task<Data, Error>] = [:]
    public init(runtime: any CSPRuntimeProvider, session: URLSession = .shared) {
        self.init(runtime: runtime, session: session, localOverride: nil)
    }
    init(runtime: any CSPRuntimeProvider, session: URLSession, localOverride: URLSession?) {
        self.runtime = runtime; upstream = session
        #if arch(x86_64)
        callTimeout = 180
        #else
        callTimeout = 40
        #endif
        let configuration = URLSessionConfiguration.ephemeral
        configuration.connectionProxyDictionary = [:]; configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = callTimeout + 10; configuration.timeoutIntervalForResource = callTimeout + 15
        local = localOverride ?? URLSession(configuration: configuration, delegate: CSPNoRedirect(), delegateQueue: nil)
    }
    private func component(_ definition: CSPComponent) async throws -> Data {
        if let task = components[definition] { return try await task.value }
        if components.count >= 16 { components.removeAll() }
        let session = upstream
        let task = Task<Data, Error> {
            let data: Data
            if definition.url.isFileURL {
                let size = try definition.url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? Int.max
                guard size <= 16 * 1024 * 1024 else { throw TVError.message("爬虫组件超过 16 MB。") }
                data = try Data(contentsOf: definition.url)
            } else {
                var request = URLRequest(url: definition.url, timeoutInterval: 30)
                // The same unversioned URL often serves a new JAR. Only our
                // already-verified in-memory task may be reused across calls.
                request.cachePolicy = .reloadIgnoringLocalCacheData
                request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
                request.setValue("no-cache", forHTTPHeaderField: "Pragma")
                request.setValue("TVBoxMac/1.0", forHTTPHeaderField: "User-Agent")
                let (bytes, response) = try await session.bytes(for: request)
                guard let response = response as? HTTPURLResponse, (200..<300).contains(response.statusCode) else { throw TVError.message("无法下载爬虫组件，请刷新源配置后重试。") }
                var result = Data()
                for try await byte in bytes {
                    if result.count >= 16 * 1024 * 1024 { throw TVError.message("爬虫组件超过 16 MB。") }
                    result.append(byte)
                }
                data = result
            }
            guard data.starts(with: [0x50, 0x4b]) else { throw TVError.message("下载内容不是有效的 JAR 组件，请刷新源配置。") }
            if let algorithm = definition.algorithm, let expected = definition.digest {
                let digest = algorithm == .sha256 ? SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() : Insecure.MD5.hash(data: data).map { String(format: "%02x", $0) }.joined()
                guard digest == expected else { throw CSPFailure.componentChecksumMismatch }
            }
            return data
        }
        components[definition] = task
        do { return try await task.value }
        catch { components.removeValue(forKey: definition); throw error }
    }
    public func invoke(site: Site, command: CSPCommand, arguments: [String: String]) async throws -> Data {
        try await perform(site: site, command: command, arguments: arguments).data
    }
    public func playback(site: Site, arguments: [String: String]) async throws -> CSPPlayback {
        let response = try await perform(site: site, command: .player, arguments: arguments)
        guard var object = try JSONSerialization.jsonObject(with: response.data) as? [String: Any],
              let raw = object["url"] as? String,
              let target = Self.proxyTarget(raw, connection: response.connection, session: response.session) else {
            return try CSPPlayback(data: response.data, headers: site.headers)
        }
        // Validate ordinary playback flags and headers before trusting any
        // runtime-local URL. No plugin-controlled flag can authorize loopback.
        object["url"] = "https://fixture.invalid/runtime-proxy-validation"
        let checked = try CSPPlayback(data: JSONSerialization.data(withJSONObject: object), headers: site.headers)
        let relay = CastMediaRelay(source: target, headers: ["Authorization": "Bearer " + response.connection.token], peer: "127.0.0.1")
        let lease = CSPPlaybackLease(relay)
        do {
            let url = try await relay.start()
            try Task.checkCancellation()
            return CSPPlayback(url: url, headers: checked.headers, lease: lease)
        } catch { lease.stop(); throw error }
    }
    static func proxyTarget(_ raw: String, connection: CSPWorkerConnection, session: String) -> URL? {
        guard session.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil, raw.utf8.count <= 16_384,
              !raw.contains("\r"), !raw.contains("\n"), !raw.contains("#"),
              let expression = try? NSRegularExpression(pattern: #"^http://(?:127\.0\.0\.1|localhost|\[::1\]|192\.168\.127\.2)(?::(?:-1|[0-9]{1,5}))?/proxy\?(.+)$"#, options: [.caseInsensitive]),
              let match = expression.firstMatch(in: raw, range: NSRange(raw.startIndex..., in: raw)),
              let range = Range(match.range(at: 1), in: raw) else { return nil }
        return URL(string: responseMediaPath(connection.endpoint, session: session) + "?" + raw[range])
    }
    private static func responseMediaPath(_ endpoint: URL, session: String) -> String {
        endpoint.appendingPathComponent("media").appendingPathComponent(session).appendingPathComponent("proxy").absoluteString
    }
    private func perform(site: Site, command: CSPCommand, arguments: [String: String]) async throws -> (data: Data, connection: CSPWorkerConnection, session: String) {
        guard let definition = site.csp else { throw TVError.message("CSP 接口缺少爬虫组件信息，请刷新配置。") }
        let data = try await component(definition.component)
        try Task.checkCancellation()
        let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let connection = try await runtime.connection(componentHash: hash)
        try Task.checkCancellation()
        let identity = try JSONSerialization.data(withJSONObject: ["key": site.key, "class": definition.className, "component": hash, "extend": definition.extend, "headers": site.headers], options: [.sortedKeys])
        let session = SHA256.hash(data: identity).map { String(format: "%02x", $0) }.joined()
        let loadKey = connection.token + session
        let module: [String: Any] = ["protocol": 1, "command": "load", "session": session, "class": definition.className, "extend": definition.extend, "sha256": hash, "module": data.base64EncodedString()]
        try await ensureLoaded(module, key: loadKey, connection: connection)
        try Task.checkCancellation()
        let encoded = try JSONSerialization.data(withJSONObject: arguments, options: [.sortedKeys])
        let callKey = loadKey + command.rawValue + SHA256.hash(data: encoded).map { String(format: "%02x", $0) }.joined()
        // Discovery loads categories and recommendations together. Share only
        // concurrent identical calls; subsequent refreshes still reach the source.
        if let pending = calls[callKey] { return (try await pending.value, connection, session) }
        let task = Task<Data, Error> {
            let payload: [String: Any] = ["protocol": 1, "command": command.rawValue, "session": session, "args": arguments]
            let response: [String: Any]
            do { response = try await self.request(payload, connection: connection) }
            catch CSPWorkerFailure.sessionMissing {
                // Android can restart a killed Worker without rebooting the VM.
                // Reinitialize this source once; never retain a stale load cache.
                self.loads.removeValue(forKey: loadKey)
                try await self.ensureLoaded(module, key: loadKey, connection: connection)
                response = try await self.request(payload, connection: connection)
            }
            guard let value = response["result"], JSONSerialization.isValidJSONObject(value) else { throw TVError.message("爬虫运行组件未返回有效的数据。") }
            return try JSONSerialization.data(withJSONObject: value)
        }
        calls[callKey] = task
        defer { calls.removeValue(forKey: callKey) }
        return (try await task.value, connection, session)
    }
    private func ensureLoaded(_ module: [String: Any], key: String, connection: CSPWorkerConnection) async throws {
        if loads[key] == nil {
            if loads.count >= 32 { loads.removeAll() }
            loads[key] = Task {
                let response = try await self.request(module, connection: connection)
                guard response["loaded"] as? Bool == true else { throw TVError.message("爬虫组件未能完成初始化，请重试。") }
            }
        }
        do { try await loads[key]?.value }
        catch { loads.removeValue(forKey: key); throw error }
    }
    private func request(_ payload: [String: Any], connection: CSPWorkerConnection) async throws -> [String: Any] {
        var request = URLRequest(url: connection.endpoint.appendingPathComponent("rpc"), timeoutInterval: callTimeout + 10)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer " + connection.token, forHTTPHeaderField: "Authorization")
        var timed = payload; timed["timeout"] = Int(callTimeout)
        request.httpBody = try JSONSerialization.data(withJSONObject: timed)
        let (bytes, response) = try await local.bytes(for: request)
        var data = Data()
        for try await byte in bytes {
            guard data.count < 8 * 1024 * 1024 else { throw TVError.message("爬虫返回的数据过大。") }
            data.append(byte)
        }
        try Task.checkCancellation()
        guard let http = response as? HTTPURLResponse, [200, 504].contains(http.statusCode),
              data.count <= 8 * 1024 * 1024,
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw TVError.message("爬虫运行组件连接中断，请重试。")
        }
        if let error = object["error"] as? String {
            if error == "SESSION_MISSING" { throw CSPWorkerFailure.sessionMissing }
            let message: String
            switch error {
            case "ENTRY_CLASS_MISSING": throw CSPFailure.entryClassMissing
            case "SDK_ABI_MISMATCH": message = "此爬虫与当前运行时的接口版本不兼容，请更新对应组件或软件。"
            case "NATIVE_DEPENDENCY_MISSING": message = "此爬虫依赖的安卓原生组件未能加载。"
            case "CLASS_DEPENDENCY_MISSING": message = "此爬虫缺少所需的运行库，暂不能调用。"
            case "SPIDER_RESULT_EMPTY": message = "此接口没有返回播放或内容数据，请切换其他条目或线路，或更新源配置。"
            case "SPIDER_TIMEOUT": message = "爬虫接口响应超时，请稍后重试。"
            case "WORKER_RESTART_REQUIRED", "SESSION_MISSING": message = "爬虫运行组件已重启，请重试当前接口。"
            case "MODULE_HASH_MISMATCH", "BAD_MODULE": message = "爬虫组件无效，请刷新配置后重试。"
            default: message = "爬虫接口调用失败，请重试或切换接口。"
            }
            throw TVError.message(message)
        }
        guard http.statusCode == 200 else { throw TVError.message("爬虫运行组件连接中断，请重试。") }
        return object
    }
}
