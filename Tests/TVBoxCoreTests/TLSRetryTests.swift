import Foundation
import Testing
@testable import TVBoxCore

@Suite struct TLSRetryTests {
    private func fixture(_ path: String) -> (TVService, URL) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [TLSRetryProtocol.self]
        return (TVService(session: URLSession(configuration: configuration)), URL(string: "https://\(UUID().uuidString).invalid/\(path)?token=fixture")!)
    }
    @Test func transientTLSSucceedsOnSecondRequestAndPreservesHeaders() async throws {
        let (service, url) = fixture("transient")
        let bytes = try await service.data(at: url, headers: ["Authorization": "Bearer fixture", "User-Agent": "RetryFixture"])
        let fields = try JSONSerialization.jsonObject(with: bytes) as! [String: String]
        #expect(fields["auth"] == "Bearer fixture")
        #expect(fields["ua"] == "RetryFixture")
        #expect(fields["query"] == "token=fixture")
        #expect(TLSRetryProtocol.count(url) == 2)
    }
    @Test func repeatedTLSStopsAfterOneRetryWithChineseMessage() async throws {
        let (service, url) = fixture("persistent")
        do { _ = try await service.data(at: url); Issue.record("Expected failure") }
        catch {
            #expect(error.localizedDescription.contains("已自动重试 1 次"))
            #expect(error.localizedDescription.contains("安全连接"))
            #expect(!error.localizedDescription.contains("A TLS error"))
            #expect(!error.localizedDescription.contains("token=fixture"))
        }
        #expect(TLSRetryProtocol.count(url) == 2)
    }
    @Test func changedErrorOnRetryStillHasReadableMessage() async throws {
        let (service, url) = fixture("changed-error")
        do { _ = try await service.data(at: url); Issue.record("Expected failure") }
        catch { #expect(error.localizedDescription.contains("已自动重试 1 次，仍未能获取数据")) }
        #expect(TLSRetryProtocol.count(url) == 2)
    }
    @Test func certificateAndHTTPFailureDoNotTriggerTLSRetry() async throws {
        for path in ["certificate", "forbidden"] {
            let (service, url) = fixture(path)
            do { _ = try await service.data(at: url); Issue.record("Expected failure") }
            catch {
                #expect(error.localizedDescription.contains(path == "certificate" ? "证书" : "403"))
            }
            #expect(TLSRetryProtocol.count(url) == 1)
        }
    }
    @Test func cancellationDuringRetryDelayDoesNotStartSecondRequest() async throws {
        let (service, url) = fixture("persistent")
        let task = Task { try await service.data(at: url) }
        for _ in 0..<100 {
            if TLSRetryProtocol.count(url) > 0 { break }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        #expect(TLSRetryProtocol.count(url) == 1)
        task.cancel()
        do { _ = try await task.value; Issue.record("Expected cancellation") }
        catch { #expect(error is CancellationError) }
        #expect(TLSRetryProtocol.count(url) == 1)
    }
}

private final class TLSRetryProtocol: URLProtocol {
    private static let lock = NSLock()
    private static var counts: [URL: Int] = [:]
    static func count(_ url: URL) -> Int { lock.lock(); defer { lock.unlock() }; return counts[url] ?? 0 }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let url = request.url!
        Self.lock.lock(); Self.counts[url, default: 0] += 1; let count = Self.counts[url]!; Self.lock.unlock()
        if url.path == "/certificate" { client?.urlProtocol(self, didFailWithError: URLError(.serverCertificateUntrusted)); return }
        if url.path != "/forbidden", count == 1 || url.path == "/persistent" {
            let tls = NSError(domain: NSURLErrorDomain, code: URLError.secureConnectionFailed.rawValue, userInfo: [NSLocalizedDescriptionKey: "A TLS error caused the secure connection to fail."])
            let outer = NSError(domain: "Wrapper", code: 1, userInfo: [NSUnderlyingErrorKey: tls])
            client?.urlProtocol(self, didFailWithError: outer); return
        }
        if url.path == "/changed-error" { client?.urlProtocol(self, didFailWithError: URLError(.timedOut)); return }
        let fields = ["auth": request.value(forHTTPHeaderField: "Authorization") ?? "", "ua": request.value(forHTTPHeaderField: "User-Agent") ?? "", "query": url.query ?? ""]
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: url, statusCode: url.path == "/forbidden" ? 403 : 200, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: try! JSONSerialization.data(withJSONObject: fields))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
