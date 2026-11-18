import Foundation

public enum CSPCommand: String, Codable, Sendable {
    case home, homeVideo, category, detail, search, player
}

/// The transport is implemented by the Mac's private Android runtime manager.
/// Keeping it injectable permits real protocol tests without executing a JAR
/// in the application process or mixing subscriptions' spider sessions.
public protocol CSPTransport: Sendable {
    func invoke(site: Site, command: CSPCommand, arguments: [String: String]) async throws -> Data
    func playback(site: Site, arguments: [String: String]) async throws -> CSPPlayback
}
public extension CSPTransport {
    func playback(site: Site, arguments: [String: String]) async throws -> CSPPlayback {
        try CSPPlayback(data: await invoke(site: site, command: .player, arguments: arguments), headers: site.headers)
    }
}

/// A playback owns its temporary media endpoint; releasing it closes requests.
public final class CSPPlaybackLease: @unchecked Sendable {
    private let relay: CastMediaRelay
    init(_ relay: CastMediaRelay) { self.relay = relay }
    public func stop() { relay.stop() }
    deinit { relay.stop() }
}

public struct CSPPlayback: Sendable {
    public let url: URL
    public let headers: [String: String]
    public let lease: CSPPlaybackLease?
    init(url: URL, headers: [String: String], lease: CSPPlaybackLease) {
        self.url = url; self.headers = headers; self.lease = lease
    }
    public init(data: Data, headers: [String: String] = [:]) throws {
        guard let result = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw TVError.message("爬虫未返回有效的播放结果。") }
        func flag(_ key: String) throws -> Int {
            guard let value = result[key], !(value is NSNull) else { return 0 }
            if let number = value as? NSNumber, number.doubleValue.rounded() == number.doubleValue { return number.intValue }
            if let text = value as? String, let number = Int(text) { return number }
            throw TVError.message("爬虫返回的播放解析标记无效，请切换线路。")
        }
        let parse = try flag("parse"), jx = try flag("jx")
        guard parse == 0, jx == 0 else { throw TVError.message("此线路还需要网页解析，请选择可直接播放的线路。") }
        guard let value = result["url"] as? String, let url = URL(string: value),
              ["https", "http", "rtsp", "rtmp"].contains(url.scheme?.lowercased() ?? ""), url.host != nil else {
            throw TVError.message("爬虫没有提供可播放的视频地址。此线路可能需要登录或已失效。")
        }
        let host = url.host?.lowercased() ?? ""
        guard host != "localhost", host != "::1", host != "[::1]", !host.hasPrefix("127."),
              host != "192.168.127.2", host != "0.0.0.0" else {
            throw TVError.message("此线路需要安卓本地视频代理，当前版本暂不支持，请切换可直接播放的线路。")
        }
        self.url = url
        var supplied = result["header"] as? [String: String]
        if supplied == nil, let text = result["header"] as? String, let bytes = text.data(using: .utf8) {
            supplied = try JSONSerialization.jsonObject(with: bytes) as? [String: String]
        }
        var merged = headers
        for (name, value) in supplied ?? [:] {
            guard name.range(of: #"^[!#$%&'*+.^_`|~0-9A-Za-z-]+$"#, options: .regularExpression) != nil,
                  value.rangeOfCharacter(from: .newlines) == nil else { throw TVError.message("爬虫返回的播放请求头格式无效。") }
            for old in merged.keys.filter({ $0.caseInsensitiveCompare(name) == .orderedSame }) { merged.removeValue(forKey: old) }
            merged[name] = value
        }
        self.headers = merged
        self.lease = nil
    }
}
