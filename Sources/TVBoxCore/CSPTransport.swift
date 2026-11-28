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

public enum CSPPlaybackAuthorization: LocalizedError, Sendable, Equatable {
    case code(String)
    case image(Data)

    public var errorDescription: String? {
        "片源要求扫码授权。请完成授权后重试播放。"
    }

    fileprivate init?(result: [String: Any]) {
        let envelopes = Self.envelopes(result)
        let contexts = Self.authContexts(envelopes)
        for fields in contexts + envelopes {
            if let challenge = Self.decode(fields, textKeys: ["qrcode", "qrCode", "qr", "qr_content", "qrContent", "qr_url", "qrUrl"],
                                           imageKeys: ["qr_image", "qrImage", "qr_base64", "qrBase64"]) {
                self = challenge
                return
            }
            for key in ["qrcode", "qrCode", "qr"] {
                guard let qr = fields[key] as? [String: Any] else { continue }
                if let challenge = Self.decode(qr, textKeys: ["content", "code", "payload", "url", "text"],
                                               imageKeys: ["image", "base64", "imageBase64"]) {
                    self = challenge
                    return
                }
            }
        }
        for auth in contexts where Self.isQRType(auth) {
            if let challenge = Self.decode(auth, textKeys: ["content", "payload", "url", "text"], imageKeys: ["image", "base64"]) {
                self = challenge
                return
            }
        }
        return nil
    }

    fileprivate static func explicitlyRequired(in result: [String: Any]) -> Bool {
        let rows = envelopes(result)
        if authContexts(rows).contains(where: { ($0["required"] as? Bool) ?? isQRType($0) }) { return true }
        return rows.contains { fields in
            ["code", "status", "error"].contains { key in
                guard let value = fields[key] as? String else { return false }
                return ["qr_required", "qrcode_required", "qr_login_required"].contains(value.lowercased())
            }
        }
    }

    private static func envelopes(_ result: [String: Any]) -> [[String: Any]] {
        [result] + ["data", "error", "result"].compactMap { result[$0] as? [String: Any] }
    }

    private static func authContexts(_ envelopes: [[String: Any]]) -> [[String: Any]] {
        envelopes.flatMap { fields in ["auth", "authorization", "login"].compactMap { fields[$0] as? [String: Any] } }
    }

    private static func isQRType(_ fields: [String: Any]) -> Bool {
        let type = (fields["type"] as? String ?? fields["method"] as? String)?.lowercased()
        return type.map { ["qr", "qrcode", "qr_code", "scan"].contains($0) } ?? false
    }

    private static func decode(_ fields: [String: Any], textKeys: [String], imageKeys: [String]) -> Self? {
        for key in imageKeys + textKeys {
            guard let raw = fields[key] as? String, raw.utf8.count <= 350_000 else { continue }
            let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty else { continue }
            if value.lowercased().hasPrefix("data:") {
                guard let comma = value.firstIndex(of: ","),
                      ["data:image/png;base64", "data:image/jpeg;base64"].contains(value[..<comma].lowercased()),
                      let image = inlineImage(String(value[value.index(after: comma)...])) else { continue }
                return .image(image)
            }
            if let image = inlineImage(value) { return .image(image) }
            if textKeys.contains(key), value.utf8.count <= 1024,
               value.rangeOfCharacter(from: .controlCharacters) == nil { return .code(value) }
        }
        return nil
    }

    private static func inlineImage(_ encoded: String) -> Data? {
        guard let data = Data(base64Encoded: encoded), data.count <= 256 * 1024 else { return nil }
        let png = data.starts(with: [137, 80, 78, 71, 13, 10, 26, 10])
        let jpeg = data.starts(with: [255, 216, 255])
        return png || jpeg ? data : nil
    }
}

public struct CSPPlaybackLoginRequired: LocalizedError, Sendable {
    public let sourceMessage: String?

    public var errorDescription: String? {
        "片源要求登录，但没有提供二维码。请在片源端授权，或切换线路。"
    }

    fileprivate init(messages: [String]) {
        sourceMessage = messages.lazy.compactMap(Self.safeMessage).first
    }

    private static func safeMessage(_ raw: String) -> String? {
        // Provider text is untrusted. Preserve readable directions while
        // stripping link destinations, credential values and invisible controls.
        let markup = String(raw.prefix(4096))
            .replacingOccurrences(of: #"(?is)<(script|style)\b[^>]*>.*?</\1\s*>"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"(?i)<br\s*/?>"#, with: "\n", options: .regularExpression)
        var text = Parser.plainText(markup)
        text.unicodeScalars.removeAll { scalar in
            (scalar.properties.generalCategory == .control && scalar != "\n" && scalar != "\t") ||
                scalar.properties.generalCategory == .format
        }
        let redactions = [
            (#"(?i)(?:\b[a-z][a-z0-9+.-]+://|//|\bwww\.)[^\s<>"'，。；、）】]+"#, "[…]"),
            (#"(?i)\b(?:[a-z0-9-]+\.)+[a-z]{2,}[/?:#][^\s<>"'，。；、）】]*"#, "[…]"),
            (#"(?i)(\b(?:set-cookie|cookie)\s*["']?\s*[:：=]\s*)(?=[\w-]{1,64}\s*=)[^\r\n，。；]+"#, "$1[…]"),
            (#"(?i)((?:cookie|authorization|access[_-]?token|refresh[_-]?token|token|session[_-]?id|session|sid|password|passwd|passcode|pwd|验证码|密码|提取码|__puus|__pus|sessdata|bduss)\s*["']?\s*[:：=]\s*)(?:bearer\s+)?(?:"[^"\r\n]*"|'[^'\r\n]*'|[a-z0-9._~%+/=\-]+)"#, "$1[…]"),
            (#"(?i)\bbearer\s+[a-z0-9._~%+/=\-]+"#, "Bearer […]"),
            (#"[a-zA-Z0-9._~%+/=\-]{32,}"#, "[…]")
        ]
        for (pattern, replacement) in redactions {
            text = text.replacingOccurrences(of: pattern, with: replacement, options: .regularExpression)
        }
        text = text.split(whereSeparator: \.isNewline).map { line in
            line.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        }.filter { !$0.isEmpty }.joined(separator: "\n")
        guard !text.isEmpty, text.range(of: #"^[A-Za-z0-9_-]+$"#, options: .regularExpression) == nil,
              text.rangeOfCharacter(from: .letters) != nil else { return nil }
        return text.count > 560 ? String(text.prefix(560)) + "…" : text
    }
}

public enum CSPPlaybackUnavailable: LocalizedError, Sendable {
    case missing, expired, unsupportedProtocol, webParsing

    public var errorDescription: String? {
        switch self {
        case .missing: return "片源报告找不到该视频，请切换线路或刷新源配置。"
        case .expired: return "片源报告视频已下架或链接已失效，请切换线路或刷新源配置。"
        case .unsupportedProtocol: return "片源返回的播放地址使用了不支持的协议，请切换线路。"
        case .webParsing: return "此线路还需要网页解析，请选择可直接播放的线路。"
        }
    }
}

public struct CSPPlayback: Sendable {
    public let url: URL
    public let headers: [String: String]
    public let lease: CSPPlaybackLease?
    init(url: URL, headers: [String: String], lease: CSPPlaybackLease) {
        self.url = url; self.headers = headers; self.lease = lease
    }
    public init(data: Data, headers: [String: String] = [:]) throws {
        guard let result = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw TVError.message("片源返回的播放结果格式无效，请重试或切换线路。")
        }
        func flag(_ key: String) throws -> Int {
            guard let value = result[key], !(value is NSNull) else { return 0 }
            if let number = value as? NSNumber, number.doubleValue.rounded() == number.doubleValue { return number.intValue }
            if let text = value as? String, let number = Int(text) { return number }
            throw TVError.message("爬虫返回的播放解析标记无效，请切换线路。")
        }
        let rawURL = (result["url"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let url = rawURL.flatMap { URL(string: $0) }
        let scheme = url?.scheme?.lowercased()
        let supportedScheme = scheme.map { ["https", "http", "rtsp", "rtmp"].contains($0) } ?? false
        let host = url?.host?.lowercased()
        let hasPlaybackAddress = supportedScheme && host?.isEmpty == false
        if !hasPlaybackAddress || CSPPlaybackAuthorization.explicitlyRequired(in: result) {
            if let authorization = CSPPlaybackAuthorization(result: result) { throw authorization }
            if let reason = Self.reportedFailure(in: result, rawURL: rawURL) { throw reason }
        }
        let parse = try flag("parse"), jx = try flag("jx")
        if parse != 0 || jx != 0, let authorization = CSPPlaybackAuthorization(result: result) {
            throw authorization
        }
        guard parse == 0, jx == 0 else { throw CSPPlaybackUnavailable.webParsing }
        if result["url"] == nil || result["url"] is NSNull || rawURL?.isEmpty == true {
            throw TVError.message("片源未返回本线路的播放地址，请重试或切换线路。")
        }
        if scheme != nil && !supportedScheme {
            throw CSPPlaybackUnavailable.unsupportedProtocol
        }
        guard let url, supportedScheme, let host, !host.isEmpty else {
            throw TVError.message("片源返回的播放地址格式不正确，请重试或切换线路。")
        }
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

    /// Classify source responses using fixed UI labels. Only a recognized
    /// login error can carry a sanitized provider message into the player.
    private static func reportedFailure(in result: [String: Any], rawURL: String?) -> Error? {
        let fields = ["msg", "message", "error", "code", "status", "statusCode"]
        let envelopes = [result] + ["error", "data", "auth"].compactMap { result[$0] as? [String: Any] }
        let messages = envelopes.flatMap { row in
            ["msg", "message", "detail", "error"].compactMap { row[$0] as? String }
        }
        func loginRequired(matched text: String) -> CSPPlaybackLoginRequired {
            CSPPlaybackLoginRequired(messages: messages + [text])
        }
        var values = envelopes.flatMap { row in fields.map { row[$0] } }
        // Some crawlers put a human-readable error in the URL field. A numeric
        // value in that field can also be an episode ID, so don't treat it as a status.
        if let rawURL, Int(rawURL) == nil { values.append(rawURL) }
        let trim = CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "。！!."))
        for value in values {
            guard let text = (value as? String) ?? (value as? NSNumber)?.stringValue else { continue }
            let status = String(text.prefix(1024)).trimmingCharacters(in: trim).lowercased()
            switch status {
            case "401", "unauthorized", "login_required", "login required", "请登录", "请先登录", "请先登录后播放", "登录后观看", "需要登录", "登录已过期", "登录失效", "请扫码登录", "需要扫码授权", "qr_required", "qrcode_required", "qr_login_required":
                return loginRequired(matched: text)
            case "403", "forbidden", "permission_denied", "access denied", "vip_required", "无权限", "权限不足", "拒绝访问", "需要会员", "会员专享", "仅限会员观看":
                return TVError.message("片源拒绝访问或要求额外权限，请检查片源权限，或切换线路。")
            case "404", "not_found", "not found", "资源不存在", "视频不存在", "影片不存在":
                return CSPPlaybackUnavailable.missing
            case "410", "gone", "expired", "url_expired", "link expired", "链接已失效", "链接已过期", "播放地址已失效", "播放地址已过期", "视频已下架", "已下架":
                return CSPPlaybackUnavailable.expired
            case "408", "504", "timeout", "request timeout", "gateway timeout", "请求超时", "连接超时", "网络超时":
                return TVError.message("片源报告请求超时，请稍后重试。")
            case "429", "too many requests", "rate_limited", "请求过于频繁", "访问过于频繁":
                return TVError.message("片源限制了请求频率，请稍后重试。")
            case "500", "502", "503", "server_error", "service unavailable", "服务器错误", "服务暂不可用":
                return TVError.message("片源报告服务暂不可用，请稍后重试或切换线路。")
            default:
                let asksToConfigureLogin = status.contains("cookie") && status.contains("配置") &&
                    status.contains("登录") && ["请先", "请在", "请到", "需要"].contains(where: status.contains)
                if ["请先登录", "请先扫码", "请配置登录"].contains(where: status.hasPrefix) ||
                    asksToConfigureLogin ||
                    (status.contains("cookie") && ["请配置", "请先配置", "未配置", "已失效", "已过期", "missing", "expired", "required"].contains(where: status.contains)) {
                    return loginRequired(matched: text)
                }
                continue
            }
        }
        return nil
    }
}
