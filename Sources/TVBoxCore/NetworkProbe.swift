import Foundation
import CryptoKit

public enum ProbeTargetKind: String, CaseIterable, Sendable {
    case vod = "点播接口", live = "直播订阅", subscription = "子配置订阅"
}

public struct ProbeRequestKey: Hashable, Sendable {
    public let kind: ProbeTargetKind
    public let url: String
    public let headers: [String: String]
    public init(kind: ProbeTargetKind, url: String, headers: [String: String] = [:]) {
        self.kind = kind; self.url = url
        self.headers = Dictionary(headers.sorted { $0.key < $1.key }.map { ($0.key.lowercased(), $0.value) }, uniquingKeysWith: { _, last in last })
    }
    var identifier: String {
        let identity = [kind.rawValue, url] + headers.sorted { $0.key < $1.key }.map { "\($0.key.utf8.count):\($0.key)\($0.value.utf8.count):\($0.value)" }
        return SHA256.hash(data: Data(identity.joined(separator: "\n").utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

public struct ProbeTarget: Identifiable, Hashable, Sendable {
    public let id: String
    public var names: [String]
    public let kind: ProbeTargetKind
    public let url: String
    public let headers: [String: String]
    public var supportedInApp: Bool
    public init(id: String, name: String, kind: ProbeTargetKind, url: String, headers: [String: String] = [:], supportedInApp: Bool = true) {
        self.id = id; names = [name]; self.kind = kind; self.url = url; self.headers = headers; self.supportedInApp = supportedInApp
    }
    public var name: String { names.first ?? "未命名地址" }
    public var displayURL: String {
        guard var parts = URLComponents(string: url) else { return "无效地址" }
        parts.user = nil; parts.password = nil; parts.query = nil; parts.fragment = nil
        return parts.string ?? "无效地址"
    }
}

/// Only configured endpoints and subscriptions; no expansion into channel media URLs.
public struct ProbeCatalog: Sendable {
    public let targets: [ProbeTarget]
    public let skippedCount: Int
    public init(library: SourceLibrary) {
        var targets: [ProbeTarget] = [], positions: [ProbeRequestKey: Int] = [:], skipped = 0
        func append(_ target: ProbeTarget) {
            guard let url = URL(string: target.url), ["http", "https"].contains(url.scheme?.lowercased() ?? ""), url.host != nil else { skipped += 1; return }
            // HTTP header names are case insensitive; different credentials remain distinct.
            let key = ProbeRequestKey(kind: target.kind, url: target.url, headers: target.headers)
            if let index = positions[key] {
                if target.supportedInApp && !targets[index].supportedInApp {
                    targets[index].names.removeAll { $0 == target.name }; targets[index].names.insert(target.name, at: 0)
                } else if !targets[index].names.contains(target.name) { targets[index].names.append(target.name) }
                targets[index].supportedInApp = targets[index].supportedInApp || target.supportedInApp
            } else {
                let canonical = ProbeTarget(id: key.identifier, name: target.name, kind: target.kind, url: target.url, headers: key.headers, supportedInApp: target.supportedInApp)
                positions[key] = targets.count; targets.append(canonical)
            }
        }
        for source in library.vodSources {
            for site in source.configuration.sites {
                append(ProbeTarget(id: source.id + ":site:" + site.key, name: source.name + " · " + site.name, kind: .vod, url: site.api, headers: site.headers, supportedInApp: site.supported))
            }
            for item in source.configuration.subscriptions {
                append(ProbeTarget(id: source.id + ":subscription:" + item.id, name: source.name + " · " + item.name, kind: .subscription, url: item.url))
            }
        }
        for source in library.liveSources {
            for feed in source.feeds {
                append(ProbeTarget(id: source.id + ":feed", name: source.name, kind: .live, url: feed.url, headers: feed.headers))
            }
            for item in source.subscriptions {
                append(ProbeTarget(id: source.id + ":subscription:" + item.id, name: source.name + " · " + item.name, kind: .subscription, url: item.url))
            }
        }
        self.targets = targets; skippedCount = skipped
    }
}

public struct ProbeResult: Equatable, Sendable {
    public enum Outcome: Equatable, Sendable { case success, httpError, networkError, cancelled }
    public let targetID: String
    public let outcome: Outcome
    public let statusCode: Int?
    public let milliseconds: Int
    public let method: String
    public let message: String
    public let checkedAt: Date
    public var isFailure: Bool { outcome == .httpError || outcome == .networkError }
    public init(targetID: String, outcome: Outcome, statusCode: Int? = nil, milliseconds: Int = 0, method: String = "HEAD", message: String) {
        self.targetID = targetID; self.outcome = outcome; self.statusCode = statusCode; self.milliseconds = milliseconds; self.method = method; self.message = message; checkedAt = Date()
    }
    public static func cancelled(_ id: String) -> Self { Self(targetID: id, outcome: .cancelled, message: "已取消") }
}

public struct NetworkProber: Sendable {
    private let configuration: @Sendable () -> URLSessionConfiguration
    public init(configuration: @escaping @Sendable () -> URLSessionConfiguration = { .ephemeral }) { self.configuration = configuration }
    /// Use the same GET a player would make, but finish at response headers.
    /// A successful status alone is not proof that a video can be decoded.
    func mediaStatus(url: URL, headers: [String: String]) async -> Int? {
        let target = ProbeTarget(id: "", name: "", kind: .vod, url: url.absoluteString, headers: headers)
        return await request(url, target: target, method: "GET", timeout: 2.5).status
    }
    public func probe(_ target: ProbeTarget, timeout: TimeInterval) async -> ProbeResult {
        let start = DispatchTime.now().uptimeNanoseconds
        let limit = min(30, max(0.1, timeout))
        guard let url = URL(string: target.url), ["http", "https"].contains(url.scheme?.lowercased() ?? ""), url.host != nil else {
            return ProbeResult(targetID: target.id, outcome: .networkError, message: "不是有效的 HTTP / HTTPS 地址")
        }
        var method = "HEAD"
        var response = await request(url, target: target, method: method, timeout: limit)
        if !Task.isCancelled, [405, 501].contains(response.status ?? 0) {
            let remaining = limit - Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000_000
            if remaining > 0.05 { method = "GET"; response = await request(url, target: target, method: method, timeout: remaining) }
        }
        let elapsed = Int((DispatchTime.now().uptimeNanoseconds - start) / 1_000_000)
        if Task.isCancelled || response.errorCode == URLError.cancelled.rawValue { return .cancelled(target.id) }
        if let status = response.status {
            let success = (200..<400).contains(status)
            let message: String
            switch status {
            case 200..<400: message = "正常响应"
            case 401, 403: message = "服务器可连接，但拒绝访问或需要授权"
            case 404, 410: message = "服务器可连接，地址不存在或已失效"
            case 500...599: message = "服务器返回服务端错误"
            default: message = "服务器返回 HTTP 错误"
            }
            return ProbeResult(targetID: target.id, outcome: success ? .success : .httpError, statusCode: status, milliseconds: elapsed, method: method, message: message)
        }
        let message: String
        switch response.errorCode {
        case URLError.timedOut.rawValue: message = "连接超时"
        case URLError.cannotFindHost.rawValue, URLError.dnsLookupFailed.rawValue: message = "域名解析失败"
        case URLError.cannotConnectToHost.rawValue: message = "无法连接服务器"
        case URLError.notConnectedToInternet.rawValue: message = "网络未连接"
        case URLError.networkConnectionLost.rawValue: message = "网络连接中断"
        case URLError.secureConnectionFailed.rawValue: message = "HTTPS 安全连接失败"
        case URLError.serverCertificateHasBadDate.rawValue, URLError.serverCertificateUntrusted.rawValue, URLError.serverCertificateHasUnknownRoot.rawValue, URLError.serverCertificateNotYetValid.rawValue: message = "HTTPS 证书校验失败"
        default: message = "未获得有效 HTTP 响应"
        }
        return ProbeResult(targetID: target.id, outcome: .networkError, milliseconds: elapsed, method: method, message: message)
    }
    private func request(_ url: URL, target: ProbeTarget, method: String, timeout: TimeInterval) async -> ProbeHTTPResponse {
        if Task.isCancelled { return ProbeHTTPResponse(errorCode: URLError.cancelled.rawValue) }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeout)
        request.httpMethod = method; request.setValue("TVBoxMac/0.4", forHTTPHeaderField: "User-Agent")
        for (key, value) in target.headers where !key.contains(where: { $0 == "\r" || $0 == "\n" }) && !value.contains(where: { $0 == "\r" || $0 == "\n" }) { request.setValue(value, forHTTPHeaderField: key) }
        let config = configuration(); config.urlCache = nil; config.httpCookieStorage = nil; config.httpShouldSetCookies = false
        config.timeoutIntervalForRequest = timeout; config.timeoutIntervalForResource = timeout
        return await ProbeHTTPAttempt().perform(request, configuration: config)
    }
}

private struct ProbeHTTPResponse: Sendable { var status: Int?; var errorCode: Int? }

/// Finish at HTTP response headers, including GET fallback. Never download a full feed.
private final class ProbeHTTPAttempt: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<ProbeHTTPResponse, Never>?
    private var session: URLSession?
    private var task: URLSessionDataTask?
    private var finished = false
    func perform(_ request: URLRequest, configuration: URLSessionConfiguration) async -> ProbeHTTPResponse {
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                lock.lock()
                if finished { lock.unlock(); continuation.resume(returning: ProbeHTTPResponse(errorCode: URLError.cancelled.rawValue)); return }
                self.continuation = continuation
                let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
                let task = session.dataTask(with: request)
                self.session = session; self.task = task
                lock.unlock(); task.resume()
            }
        } onCancel: { self.finish(ProbeHTTPResponse(errorCode: URLError.cancelled.rawValue)) }
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse, completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        completionHandler(.cancel)
        if let http = response as? HTTPURLResponse { finish(ProbeHTTPResponse(status: http.statusCode)) }
        else { finish(ProbeHTTPResponse(errorCode: URLError.badServerResponse.rawValue)) }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        finish(ProbeHTTPResponse(errorCode: (error as NSError?)?.code ?? URLError.badServerResponse.rawValue))
    }
    private func finish(_ response: ProbeHTTPResponse) {
        lock.lock()
        guard !finished else { lock.unlock(); return }; finished = true
        let continuation = self.continuation, session = self.session, task = self.task
        self.continuation = nil; self.session = nil; self.task = nil
        lock.unlock()
        task?.cancel(); session?.invalidateAndCancel(); continuation?.resume(returning: response)
    }
}

public enum ProbeEvent: Sendable { case started(String), finished(ProbeResult) }

public struct NetworkProbeRunner: Sendable {
    private let prober: NetworkProber
    public init(prober: NetworkProber = NetworkProber()) { self.prober = prober }
    public func run(_ targets: [ProbeTarget], concurrency: Int, timeout: TimeInterval, onEvent: @escaping @Sendable (ProbeEvent) async -> Void) async {
        await withTaskGroup(of: ProbeResult.self) { group in
            var next = 0
            func schedule(_ target: ProbeTarget) {
                group.addTask {
                    guard !Task.isCancelled else { return .cancelled(target.id) }
                    await onEvent(.started(target.id))
                    return await prober.probe(target, timeout: timeout)
                }
            }
            for _ in 0..<min(targets.count, min(8, max(1, concurrency))) { schedule(targets[next]); next += 1 }
            while let result = await group.next() {
                guard !Task.isCancelled else { group.cancelAll(); return }
                await onEvent(.finished(result))
                if !Task.isCancelled && next < targets.count { schedule(targets[next]); next += 1 }
            }
        }
    }
}
