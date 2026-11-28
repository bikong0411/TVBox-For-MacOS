import Foundation
import Testing
@testable import TVBoxCore

@Suite struct CSPDriveAuthorizationTests {
    @Test func guestMediaUsesAnOpaqueTicketAndAcceptsChangingPorts() throws {
        let endpoint = try #require(URL(string: "http://127.0.0.1:55000"))
        let connection = try CSPWorkerConnection(endpoint: endpoint, token: String(repeating: "b", count: 64))
        let ticket = String(repeating: "a", count: 32)
        for port in [24349, 32917, 54222] {
            #expect(CSPRPCTransport.guestMediaTarget(raw: "http://127.0.0.1:\(port)/file?source=opaque", ticket: ticket, connection: connection)?.absoluteString == "\(endpoint)/guest-media/\(ticket)")
        }
        for url in ["http://192.168.0.12:32917/file", "http://127.0.0.1:18793/rpc", "http://user@127.0.0.1:32917/file", "http://127.0.0.1:32917/#fragment"] {
            #expect(CSPRPCTransport.guestMediaTarget(raw: url, ticket: ticket, connection: connection) == nil)
        }
        #expect(CSPRPCTransport.guestMediaTarget(raw: "http://localhost:32917/a", ticket: "../rpc", connection: connection) == nil)
        #expect(CSPRPCTransport.guestMediaTarget(raw: "http://localhost:32917/a", ticket: nil, connection: connection) == nil)
    }

    @Test(arguments: CSPDriveProvider.allCases) func managedLoginAcceptsOnlyItsProvidersHTTPSCodes(provider: CSPDriveProvider) {
        let approved = provider == .quark ? "https://su.quark.cn/scan?token=fixture" : "https://wappass.baidu.com/scan?token=fixture"
        let other = provider == .quark ? CSPDriveProvider.baidu : .quark
        #expect(CSPDriveAuthorization.trustedCode(approved, provider: provider) == .code(approved))
        #expect(CSPDriveAuthorization.trustedCode(approved, provider: other) == nil)
        for value in ["http://wappass.baidu.com/scan", "https://wappass.baidu.com.other.invalid/scan", "https://wappass.baidu.com@other.invalid/scan", "https://wappass.baidu.com:8080/scan"] {
            #expect(CSPDriveAuthorization.trustedCode(value, provider: .baidu) == nil)
        }
        #expect(CSPDriveAuthorization.trustedCode("https://quark.cn.other.invalid/scan", provider: .quark) == nil)
    }

    @Test func playbackUsesTheProviderOfTheSelectedLine() {
        #expect(CSPDriveProvider.identify(line: "百度原画", message: "请在夸克或百度登录", site: "聚合") == .baidu)
        #expect(CSPDriveProvider.identify(line: "Quark HD", message: nil, site: "百度搜索") == .quark)
        #expect(CSPDriveProvider.identify(line: "原画", message: "请登录百度网盘", site: "聚合") == .baidu)
        #expect(CSPDriveProvider.identify(line: "原画", message: "夸克或百度", site: "聚合") == nil)
    }

    @Test(arguments: CSPDriveProvider.allCases, [true, false]) func confirmationRequiresTheMatchingProviderToReportAuthorizationSaved(provider: CSPDriveProvider, saved: Bool) async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [DriveLoginFixture.self]
        let client = URLSession(configuration: config)
        defer { client.invalidateAndCancel() }
        let path = saved ? "saved" : "temporary"
        let proxy = try #require(URL(string: "http://127.0.0.1:55000/media/\(provider.rawValue)/\(path)/proxy"))
        let authorization = try await CSPDriveAuthorization.begin(provider: provider, proxy: proxy, token: "fixture", client: client)
        let host = provider == .quark ? "su.quark.cn" : "wappass.baidu.com"
        #expect(authorization.code == .code("https://\(host)/scan?token=fixture"))
        if saved { try await authorization.waitForConfirmation(timeout: .seconds(2), pollInterval: .milliseconds(2)) }
        else { await #expect(throws: CSPDriveAuthorization.Error.self) {
            try await authorization.waitForConfirmation(timeout: .seconds(2), pollInterval: .milliseconds(2))
        } }
    }

    @Test(arguments: CSPDriveProvider.allCases) func temporaryPollingFailuresKeepTheSameChallenge(provider: CSPDriveProvider) async throws {
        let (challenge, client, proxy) = try await makeChallenge(provider: provider, scenario: "recovery")
        defer { client.invalidateAndCancel() }
        try await challenge.waitForConfirmation(timeout: .seconds(2), pollInterval: .milliseconds(2))
        #expect(DriveLoginFixture.count(proxy, "loginStart") == 1)
        #expect(DriveLoginFixture.count(proxy, "loginPoll") == 5)
        #expect(DriveLoginFixture.count(proxy, "loginCancel") == 0)
    }

    @Test func explicitProviderExpiryStillStopsPolling() async throws {
        let (challenge, client, proxy) = try await makeChallenge(provider: .baidu, scenario: "expired")
        defer { client.invalidateAndCancel() }
        do {
            try await challenge.waitForConfirmation(timeout: .seconds(2), pollInterval: .milliseconds(2))
            Issue.record("Expected the provider's expired response to stop polling")
        } catch CSPDriveAuthorization.Error.expired { }
        #expect(DriveLoginFixture.count(proxy, "loginPoll") == 1)
        #expect(DriveLoginFixture.count(proxy, "status") == 0)
    }

    @Test func waitsForAuthorizationToBeSavedThenContinues() async throws {
        let (challenge, client, proxy) = try await makeChallenge(provider: .baidu, scenario: "persisting")
        defer { client.invalidateAndCancel() }
        try await challenge.waitForConfirmation(timeout: .seconds(2), pollInterval: .milliseconds(2))
        #expect(DriveLoginFixture.count(proxy, "loginStart") == 1)
        #expect(DriveLoginFixture.count(proxy, "loginPoll") == 1)
        #expect(DriveLoginFixture.count(proxy, "status") == 3)
    }

    private func makeChallenge(provider: CSPDriveProvider, scenario: String) async throws -> (CSPDriveAuthorization, URLSession, URL) {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [DriveLoginFixture.self]
        let client = URLSession(configuration: config)
        let proxy = try #require(URL(string: "http://127.0.0.1:55000/media/\(provider.rawValue)/\(scenario)/\(UUID())/proxy"))
        return (try await CSPDriveAuthorization.begin(provider: provider, proxy: proxy, token: "fixture", client: client), client, proxy)
    }
}

private final class DriveLoginFixture: URLProtocol {
    private static let lock = NSLock()
    private static var calls: [String: Int] = [:]

    static func count(_ url: URL, _ action: String) -> Int {
        lock.withLock { calls[url.path + action, default: 0] }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let url = request.url, let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
              request.value(forHTTPHeaderField: "Authorization") == "Bearer fixture",
              let requested = query.first(where: { $0.name == "provider" })?.value,
              let provider = CSPDriveProvider(rawValue: requested), url.path.contains("/\(requested)/"),
              let action = query.first(where: { $0.name == "action" })?.value else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        let attempt = Self.lock.withLock {
            Self.calls[url.path + action, default: 0] += 1
            return Self.calls[url.path + action, default: 0]
        }
        let body: String
        var code = 200
        switch action {
        case "loginStart":
            let host = provider == .quark ? "su.quark.cn" : "wappass.baidu.com"
            body = #"{"code":0,"taskId":"fixture+id","qrUrl":"https://\#(host)/scan?token=fixture"}"#
        case "loginPoll" where url.path.contains("/recovery/") && attempt < 5 && url.absoluteString.contains("taskId=fixture%2Bid"):
            switch attempt {
            case 1:
                client?.urlProtocol(self, didFailWithError: URLError(.timedOut))
                return
            case 2: code = 503; body = ""
            case 3: body = "Incomplete response"
            default: body = #"{"status":"waiting"}"#
            }
        case "loginPoll" where url.path.contains("/expired/"): body = #"{"status":"expired","terminal":true}"#
        case "loginPoll" where url.absoluteString.contains("taskId=fixture%2Bid"): body = #"{"status":"success"}"#
        case "status":
            let saved = url.path.contains("/saved/") || (url.path.contains("/persisting/") && attempt == 3) || url.path.contains("/recovery/")
            body = #"{"quarkCookie":\#(provider == .quark ? saved : true),"baiduCookie":\#(provider == .baidu ? saved : true)}"#
        default: body = #"{"status":"error","terminal":true}"#
        }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: url, statusCode: code, httpVersion: "HTTP/1.1", headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
