import Foundation

public enum CSPDriveProvider: String, CaseIterable, Sendable {
    case quark, baidu

    private var localizedName: String { self == .quark ? "夸克" : "百度" }
    fileprivate var authorizationKey: String { rawValue + "Cookie" }

    func matches(_ label: String) -> Bool {
        label.contains(localizedName) || label.localizedCaseInsensitiveContains(rawValue)
    }

    public static func identify(line: String, message: String?, site: String) -> Self? {
        for label in [line, message ?? "", site] {
            let providers = allCases.filter { $0.matches(label) }
            if providers.count == 1 { return providers.first }
        }
        return nil
    }

    fileprivate func trusts(host: String) -> Bool {
        switch self {
        case .quark: return host == "quark.cn" || host.hasSuffix(".quark.cn")
        case .baidu: return host == "wappass.baidu.com"
        }
    }
}

/// Talks to the configuration spider in the same Android runtime as playback.
/// The provider's account state remains in that runtime.
public struct CSPDriveAuthorization: Sendable {
    public let code: CSPPlaybackAuthorization
    private let taskID: String
    private let session: Session

    public enum Error: LocalizedError {
        case unavailable, failed, expired
        public var errorDescription: String? {
            switch self {
            case .unavailable: return "当前片源的配置中心不支持此网盘的扫码登录。"
            case .failed: return "网盘扫码登录失败，请重新获取二维码。"
            case .expired: return "网盘登录二维码已过期，请重新获取。"
            }
        }
    }

    static func begin(provider: CSPDriveProvider, proxy: URL, token: String, client: URLSession) async throws -> Self {
        let session = Session(provider: provider, proxy: proxy, token: token, client: client)
        let response = try await session.call("loginStart")
        guard response["code"] as? Int == 0, let taskID = response["taskId"] as? String,
              !taskID.isEmpty, taskID.utf8.count <= 256 else { throw Error.failed }
        guard let payload = response["qrUrl"] as? String, let code = trustedCode(payload, provider: provider) else {
            _ = try? await session.call("loginCancel", taskID: taskID)
            throw Error.failed
        }
        return Self(code: code, taskID: taskID, session: session)
    }

    static func trustedCode(_ payload: String, provider: CSPDriveProvider) -> CSPPlaybackAuthorization? {
        guard payload.utf8.count <= 1024, let url = URLComponents(string: payload), url.scheme == "https",
              let host = url.host?.lowercased(), provider.trusts(host: host),
              url.user == nil, url.password == nil, url.port == nil || url.port == 443,
              payload.rangeOfCharacter(from: .controlCharacters) == nil else { return nil }
        return .code(payload)
    }

    public func waitForConfirmation(onReconnectChanged: (@MainActor @Sendable (Bool) -> Void)? = nil) async throws {
        try await waitForConfirmation(timeout: .seconds(240), pollInterval: .milliseconds(1800), onReconnectChanged: onReconnectChanged)
    }

    func waitForConfirmation(timeout: Duration, pollInterval: Duration, onReconnectChanged: (@MainActor @Sendable (Bool) -> Void)? = nil) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now + timeout
        var confirmed = false
        var unsavedChecks = 0
        var reconnecting = false
        var delay = pollInterval
        while clock.now < deadline {
            try Task.checkCancellation()
            do {
                if !confirmed {
                    let response = try await session.call("loginPoll", taskID: taskID)
                    let status = response["status"] as? String
                    confirmed = status == "success"
                    if status == "expired" { throw Error.expired }
                    if !confirmed, response["terminal"] as? Bool == true { throw Error.failed }
                }
                if confirmed {
                    let state = try await session.call("status")
                    let stored = state[session.provider.authorizationKey]
                    let text = (stored as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
                    if stored as? Bool == true || !["", "false", "0"].contains(text) { return }
                    unsavedChecks += 1
                    if unsavedChecks >= 3 { throw Error.failed }
                }
                if reconnecting { await onReconnectChanged?(false) }
                reconnecting = false
                delay = pollInterval
            } catch let failure as Error {
                throw failure
            } catch {
                try Task.checkCancellation()
                if !reconnecting { await onReconnectChanged?(true) }
                reconnecting = true
                delay = min(delay * 2, .seconds(8))
            }
            try await clock.sleep(until: min(deadline, clock.now + delay))
        }
        throw Error.expired
    }

    public func cancel() async { _ = try? await session.call("loginCancel", taskID: taskID) }

    private struct Session: Sendable {
        let provider: CSPDriveProvider
        let proxy: URL
        let token: String
        let client: URLSession

        func call(_ action: String, taskID: String? = nil) async throws -> [String: Any] {
            guard var url = URLComponents(url: proxy, resolvingAgainstBaseURL: false) else { throw Error.unavailable }
            url.queryItems = [URLQueryItem(name: "do", value: "pan"), URLQueryItem(name: "action", value: action),
                              URLQueryItem(name: "provider", value: provider.rawValue)]
            if let taskID { url.queryItems?.append(URLQueryItem(name: "taskId", value: taskID)) }
            url.percentEncodedQuery = url.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
            guard let target = url.url else { throw Error.unavailable }
            var request = URLRequest(url: target, timeoutInterval: 24)
            request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
            let (bytes, response) = try await client.bytes(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 503
            if status == 408 || status == 429 || (500...599).contains(status) { throw URLError(.badServerResponse) }
            guard status == 200 else { throw Error.failed }
            var data = Data()
            for try await byte in bytes {
                guard data.count < 512 * 1024 else { throw Error.failed }
                data.append(byte)
            }
            guard let result = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
                throw URLError(.cannotParseResponse)
            }
            return result
        }
    }
}
