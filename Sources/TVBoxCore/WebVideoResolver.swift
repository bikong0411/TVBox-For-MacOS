import CoreFoundation
import Foundation

/// Resolves media explicitly embedded in the HTML of a playback page.
public struct WebVideoResolver: Sendable {
    public enum Result: Equatable, Sendable {
        case direct
        case media(URL, headers: [String: String])
    }

    public enum Failure: LocalizedError, Equatable, Sendable {
        case noMedia
        case multipleMedia

        public var errorDescription: String? {
            switch self {
            case .noMedia:
                return "这个地址打开的是网页，未找到可直接播放的视频。请在浏览器打开，或使用片源提供的视频直链。"
            case .multipleMedia:
                return "网页中有多个视频地址，无法确定要播放哪一个。请在浏览器选择视频，或粘贴对应的直链。"
            }
        }
    }

    private static let mediaExtensions: Set<String> = [
        "m3u8", "mpd", "mp4", "m4v", "mov", "webm", "mkv", "flv", "ts",
        "mp3", "m4a", "aac", "ogg", "opus", "wav", "flac", "m2ts", "avi"
    ]
    private let configuration: URLSessionConfiguration

    public init(configuration: URLSessionConfiguration = .ephemeral) {
        let options = configuration.copy() as! URLSessionConfiguration
        options.httpShouldSetCookies = false
        options.httpCookieStorage = nil
        options.urlCredentialStorage = nil
        options.urlCache = nil
        options.timeoutIntervalForRequest = 5
        options.timeoutIntervalForResource = 8
        self.configuration = options
    }

    public static func shouldInspect(_ url: URL) -> Bool {
        isWebURL(url) && !mediaExtensions.contains(url.pathExtension.lowercased())
    }

    public func resolve(_ url: URL, headers: [String: String] = [:]) async throws -> Result {
        guard Self.shouldInspect(url) else { return .direct }
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }

        let agent = headers.first { $0.key.caseInsensitiveCompare("User-Agent") == .orderedSame }?.value
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 5)
        request.setValue("text/html, application/xhtml+xml, */*;q=0.8", forHTTPHeaderField: "Accept")
        if let agent { request.setValue(agent, forHTTPHeaderField: "User-Agent") }
        let (bytes, response) = try await session.bytes(for: request, delegate: PageRedirect())
        guard let response = response as? HTTPURLResponse,
              (200..<300).contains(response.statusCode),
              let page = response.url, Self.isWebURL(page) else { return .direct }
        let mime = response.mimeType?.lowercased()
        let declaredHTML = mime == "text/html" || mime == "application/xhtml+xml"
        guard declaredHTML || mime == "text/plain" || mime == "application/octet-stream" || mime == nil else { return .direct }

        var body = Data()
        for try await byte in bytes {
            body.append(byte)
            if !declaredHTML, body.count == 4096, !Self.looksLikeHTML(body) { return .direct }
            if body.count == 512 * 1024 { break }
        }
        guard declaredHTML || Self.looksLikeHTML(body) else { return .direct }
        let encoding = response.textEncodingName.flatMap {
            let value = CFStringConvertIANACharSetNameToEncoding($0 as CFString)
            return value == kCFStringEncodingInvalidId ? nil : String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(value))
        }
        let html = encoding.flatMap { String(data: body, encoding: $0) } ?? String(decoding: body, as: UTF8.self)
        let media = try Self.extract(from: html, page: page)
        var mediaHeaders = Self.sameOrigin(url, media) ? headers : [:]
        if let agent, !mediaHeaders.keys.contains(where: { $0.lowercased() == "user-agent" }) {
            mediaHeaders["User-Agent"] = agent
        }
        if !mediaHeaders.keys.contains(where: { ["referer", "referrer"].contains($0.lowercased()) }) {
            var referrer = URLComponents(url: page, resolvingAgainstBaseURL: true)
            referrer?.query = nil
            referrer?.fragment = nil
            if !Self.sameOrigin(page, media) { referrer?.path = "/" }
            mediaHeaders["Referer"] = referrer?.url?.absoluteString
        }
        return .media(media, headers: mediaHeaders)
    }

    static func extract(from html: String, page: URL) throws -> URL {
        let html = html.replacingOccurrences(of: #"(?s)<!--.*?(?:-->|$)"#, with: "", options: .regularExpression)
        let scripts = matches(#"(?is)<script\b[^>]*>(.*?)</script\s*>"#, in: html)
        let markup = html.replacingOccurrences(of: #"(?is)<script\b[^>]*>.*?</script\s*>"#, with: "", options: .regularExpression)
        let declaredBase = matches(#"(?is)<base\b([^>]*?)>"#, in: markup).first.flatMap { attributes($0[1])["href"] }
        let base = candidate(declaredBase, page: page, explicit: true) ?? page

        let videos = matches(#"(?is)<video\b([^>]*?)>(.*?)(?:</video\s*>|$)"#, in: markup)
        var elements: [[URL]] = []
        for video in videos {
            let attrs = attributes(video[1])
            if let url = candidate(attrs["src"], page: base, explicit: true) {
                elements.append([url])
                continue
            }
            let sources = matches(#"(?is)<source\b([^>]*?)>"#, in: video[2]).compactMap { source in
                let attrs = attributes(source[1])
                return candidate(attrs["src"], page: base, explicit: attrs["type"]?.lowercased().hasPrefix("image/") != true)
            }
            if !sources.isEmpty { elements.append(sources) }
        }
        if elements.count == 1, let first = elements.first?.first { return first }
        if let first = try unique(elements.compactMap(\.first)) { return first }

        let metadata = matches(#"(?is)<meta\b([^>]*?)>"#, in: markup).compactMap { tag in
            let attrs = attributes(tag[1])
            guard let key = attrs["property"]?.lowercased(), ["og:video", "og:video:url", "og:video:secure_url"].contains(key) else { return nil as URL? }
            return candidate(attrs["content"], page: base)
        }
        if let media = try unique(metadata) { return media }

        let literals = scripts.flatMap { script in
            matches(#""((?:\\.|[^"\\\r\n]){1,4096})"|'((?:\\.|[^'\\\r\n]){1,4096})'"#, in: script[1])
        }
        let urls = literals.compactMap { candidate(decodeLiteral($0[1].isEmpty ? $0[2] : $0[1]), page: base) }
            .filter { $0.pathExtension.lowercased() != "ts" }  // A script import may be TypeScript.
        if let media = try unique(urls) { return media }
        throw Failure.noMedia
    }

    private static func unique(_ urls: [URL]) throws -> URL? {
        guard Set(urls).count <= 1 else { throw Failure.multipleMedia }
        return urls.first
    }

    private static func candidate(_ value: String?, page: URL, explicit: Bool = false) -> URL? {
        guard let value else { return nil }
        let raw = decodeEntities(value).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty, raw.utf8.count <= 4096, !raw.contains("\\"),
              raw.rangeOfCharacter(from: .whitespacesAndNewlines.union(.controlCharacters)) == nil,
              let url = URL(string: raw, relativeTo: page)?.absoluteURL, isWebURL(url),
              page.scheme != "https" || url.scheme == "https",
              url != page, explicit || mediaExtensions.contains(url.pathExtension.lowercased()) else { return nil }
        return url
    }

    private static func isWebURL(_ url: URL) -> Bool {
        guard ["http", "https"].contains(url.scheme?.lowercased() ?? ""), url.user == nil, url.password == nil,
              let host = url.host?.lowercased(), host.contains("."), !host.contains(":") else { return false }
        let name = host.hasSuffix(".") ? String(host.dropLast()) : host
        guard !["localhost", "local", "internal", "lan", "home.arpa"].contains(where: { name == $0 || name.hasSuffix("." + $0) }) else { return false }
        // Keep explicitly entered LAN streams on the direct playback path and
        // never infer a media URL pointing at a literal local network address.
        let last = name.split(separator: ".").last ?? ""
        return last.contains(where: { $0.isASCII && $0.isLetter }) && !last.hasPrefix("0x")
    }

    private static func sameOrigin(_ lhs: URL, _ rhs: URL) -> Bool {
        func port(_ url: URL) -> Int { url.port ?? (url.scheme?.lowercased() == "https" ? 443 : 80) }
        return lhs.scheme?.lowercased() == rhs.scheme?.lowercased() && lhs.host?.lowercased() == rhs.host?.lowercased() && port(lhs) == port(rhs)
    }

    private static func looksLikeHTML(_ body: Data) -> Bool {
        let prefix = String(decoding: body.prefix(4096), as: UTF8.self)
        return prefix.range(of: #"(?is)^\s*\uFEFF?\s*(?:<!doctype\s+html\b|<(?:html|head|body|meta|script|video)(?:\s|>))"#, options: .regularExpression) != nil
    }

    private static func matches(_ pattern: String, in text: String) -> [[String]] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let string = text as NSString
        return regex.matches(in: text, range: NSRange(location: 0, length: string.length)).map { match in
            (0..<match.numberOfRanges).map { index in
                let range = match.range(at: index)
                return range.location == NSNotFound ? "" : string.substring(with: range)
            }
        }
    }

    private static func attributes(_ text: String) -> [String: String] {
        var values: [String: String] = [:]
        for entry in matches(#"\b([\w:-]+)\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s"'=<>]+))"#, in: text) {
            values[entry[1].lowercased()] = entry[2...4].first { !$0.isEmpty }
        }
        return values
    }

    private static func decodeLiteral(_ value: String) -> String {
        (try? JSONDecoder().decode(String.self, from: Data(("\"" + value + "\"").utf8)))
            ?? value.replacingOccurrences(of: #"\/"#, with: "/")
    }

    private static func decodeEntities(_ value: String) -> String {
        value.replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&#38;", with: "&")
            .replacingOccurrences(of: "&amp;", with: "&")
    }

    private final class PageRedirect: NSObject, URLSessionTaskDelegate {
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
            guard let url = request.url, WebVideoResolver.isWebURL(url),
                  response.url?.scheme != "https" || url.scheme == "https" else { completionHandler(nil); return }
            completionHandler(request)
        }
    }
}
