import Foundation
import Testing
@testable import TVBoxCore

@Suite struct NetworkProbeTests {
    private func client() -> NetworkProber {
        NetworkProber { let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [ProbeStubProtocol.self]; return config }
    }
    private func target(_ path: String = "/ok", headers: [String: String] = [:], host: String = UUID().uuidString.lowercased() + ".invalid") -> ProbeTarget {
        ProbeTarget(id: UUID().uuidString, name: "测试接口", kind: .vod, url: "https://\(host)\(path)", headers: headers)
    }
    @Test func catalogIncludesConfiguredEndpointsAndSubscriptionsOnly() throws {
        var library = SourceLibrary()
        try library.add(Configuration(name: "配置", location: "https://example.org/config.json", sites: [
            Site(key: "one", name: "接口一", type: 1, api: "https://example.org/api", headers: ["Authorization": "secret"]),
            Site(key: "two", name: "接口二", type: 1, api: "https://example.org/api", headers: ["authorization": "secret"]),
            Site(key: "other-auth", name: "其他授权", type: 1, api: "https://example.org/api", headers: ["Authorization": "other"]),
            Site(key: "csp", name: "爬虫", type: 3, api: "csp_Demo")
        ], feeds: [LiveFeed(name: "直播", url: "https://example.org/live.m3u")], channels: [Channel(name: "不展开频道", urls: ["https://example.org/media.m3u8"])], subscriptions: [Subscription(name: "子配置", url: "https://example.org/child.json")]))
        let catalog = ProbeCatalog(library: library)
        #expect(catalog.targets.count == 4)
        #expect(catalog.skippedCount == 1)
        #expect(catalog.targets.first?.names.count == 2)
        #expect(Set(catalog.targets.map(\.id)).count == catalog.targets.count)
        #expect(ProbeCatalog(library: library).targets.map(\.id) == catalog.targets.map(\.id))
        #expect(catalog.targets.filter { $0.kind == .vod }.count == 2)
        #expect(!catalog.targets.contains { $0.url.contains("media.m3u8") || $0.url.contains("config.json") })
    }
    @Test func headReturnsHTTPStatus() async {
        let item = target()
        let result = await client().probe(item, timeout: 1)
        #expect(result.outcome == .success)
        #expect(result.statusCode == 200)
        #expect(result.method == "HEAD")
        #expect(ProbeStubProtocol.requests(host: URL(string: item.url)!.host!).count == 1)
    }
    @Test func unsupportedHeadFallsBackToGetAndKeepsHeadersAndQuery() async {
        let item = target("/head-unsupported?token=a$b", headers: ["Authorization": "Bearer secret", "User-Agent": "CustomPlayer"])
        let result = await client().probe(item, timeout: 1)
        let requests = ProbeStubProtocol.requests(host: URL(string: item.url)!.host!)
        #expect(result.outcome == .success && result.method == "GET")
        #expect(requests.map(\.httpMethod) == ["HEAD", "GET"])
        #expect(requests.allSatisfy { $0.value(forHTTPHeaderField: "Authorization") == "Bearer secret" && $0.value(forHTTPHeaderField: "User-Agent") == "CustomPlayer" })
        #expect(requests.allSatisfy { $0.url?.query == "token=a$b" })
    }
    @Test func httpFailuresAreSeparateFromNetworkFailures() async {
        let forbidden = await client().probe(target("/forbidden"), timeout: 1)
        let missing = await client().probe(target("/missing"), timeout: 1)
        let dns = await client().probe(target("/dns"), timeout: 1)
        let timeout = await client().probe(target("/timeout"), timeout: 1)
        #expect(forbidden.outcome == .httpError && forbidden.statusCode == 403)
        #expect(missing.outcome == .httpError && missing.statusCode == 404)
        #expect(dns.outcome == .networkError && dns.message == "域名解析失败")
        #expect(timeout.outcome == .networkError && timeout.message == "连接超时")
    }
    @Test func cancellationUnblocksAnInFlightRequest() async throws {
        let item = target("/slow")
        let task = Task { await client().probe(item, timeout: 10) }
        let host = URL(string: item.url)!.host!
        for _ in 0..<50 {
            if !ProbeStubProtocol.requests(host: host).isEmpty { break }
            try await Task.sleep(nanoseconds: 2_000_000)
        }
        #expect(!ProbeStubProtocol.requests(host: host).isEmpty)
        task.cancel()
        let result = await task.value
        #expect(result.outcome == .cancelled)
    }
    @Test func batchHonorsConcurrencyAndDeliversEveryResultOnce() async {
        let recorder = ProbeEventRecorder()
        let items = (0..<11).map { _ in target("/delayed") }
        await NetworkProbeRunner(prober: client()).run(items, concurrency: 3, timeout: 2) { await recorder.record($0) }
        let snapshot = await recorder.snapshot()
        #expect(snapshot.peak == 3)
        #expect(snapshot.finished.count == items.count)
        #expect(Set(snapshot.finished).count == items.count)
        #expect(snapshot.active == 0)
        #expect(snapshot.failures == 0)
    }
    @Test func cancellingBatchDoesNotScheduleRemainingAddresses() async throws {
        let recorder = ProbeEventRecorder()
        let items = (0..<20).map { _ in target("/slow") }
        let runner = NetworkProbeRunner(prober: client())
        let task = Task { await runner.run(items, concurrency: 2, timeout: 10) { await recorder.record($0) } }
        for _ in 0..<50 {
            if await recorder.snapshot().active == 2 { break }
            try await Task.sleep(nanoseconds: 2_000_000)
        }
        task.cancel(); await task.value
        let snapshot = await recorder.snapshot()
        #expect(snapshot.started == 2)
        #expect(snapshot.finished.isEmpty)
    }
    @Test func reportOmitsURLCredentialsAndRequestHeaders() {
        let item = target("/api?token=secret#private", headers: ["Authorization": "Bearer hidden"], host: "user:password@example.org")
        let result = ProbeResult(targetID: item.id, outcome: .success, statusCode: 200, milliseconds: 123, message: "正常响应")
        let report = ProbeReport.text(targets: [item], results: [item.id: result])
        #expect(report.contains("https://example.org/api"))
        #expect(report.contains("123"))
        for secret in ["secret", "password", "Bearer", "hidden", "#private"] { #expect(!report.contains(secret)) }
    }
}

private actor ProbeEventRecorder {
    private var active = Set<String>()
    private var peak = 0, started = 0
    private var finished: [String] = []
    private var failures = 0
    func record(_ event: ProbeEvent) {
        switch event {
        case .started(let id): active.insert(id); started += 1; peak = max(peak, active.count)
        case .finished(let result):
            active.remove(result.targetID); finished.append(result.targetID)
            if result.outcome != .success { failures += 1 }
        }
    }
    func snapshot() -> (peak: Int, started: Int, finished: [String], active: Int, failures: Int) { (peak, started, finished, active.count, failures) }
}

private final class ProbeStubProtocol: URLProtocol, @unchecked Sendable {
    private static let recordsLock = NSLock()
    private static var records: [String: [URLRequest]] = [:]
    private let lock = NSLock()
    private var stopped = false
    private var work: DispatchWorkItem?
    static func requests(host: String) -> [URLRequest] { recordsLock.lock(); defer { recordsLock.unlock() }; return records[host] ?? [] }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.recordsLock.lock(); Self.records[request.url!.host!, default: []].append(request); Self.recordsLock.unlock()
        let item = DispatchWorkItem { [weak self] in self?.respond() }
        lock.lock(); work = item; let cancelled = stopped; lock.unlock()
        if cancelled { return }
        let delay: Double = request.url?.path == "/slow" ? 10 : (request.url?.path == "/delayed" ? 0.04 : 0.005)
        DispatchQueue.global().asyncAfter(deadline: .now() + delay, execute: item)
    }
    private func respond() {
        lock.lock(); let cancelled = stopped; lock.unlock(); guard !cancelled else { return }
        let path = request.url!.path
        if path == "/dns" || path == "/timeout" { client?.urlProtocol(self, didFailWithError: URLError(path == "/dns" ? .cannotFindHost : .timedOut)); return }
        let status = path == "/forbidden" ? 403 : (path == "/missing" ? 404 : (path == "/head-unsupported" && request.httpMethod == "HEAD" ? 405 : 200))
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: ["Content-Length": "0"])!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() { lock.lock(); stopped = true; work?.cancel(); work = nil; lock.unlock() }
}
