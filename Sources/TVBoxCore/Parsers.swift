import Foundation

private func string(_ value: Any?) -> String {
    if let s = value as? String { return s }
    if let n = value as? NSNumber { return n.stringValue }
    return ""
}

public enum Parser {
    /// Some TVBox lists append a display-only route label. Strip explicit labels
    /// without splitting arbitrary '$' characters in signed URL query values.
    public static func liveAddress(_ raw: String) -> String {
        guard let dollar = raw.lastIndex(of: "$") else { return raw }
        let suffix = String(raw[raw.index(after: dollar)...])
        let label = suffix.removingPercentEncoding ?? suffix
        guard label.count <= 160 else { return raw }
        let pattern = #"^(?:LR[•·][^\r\n]*『线路[^』\r\n]+』|线路[0-9０-９一二三四五六七八九十]+|备用线路[0-9一二三四五六七八九十]*|高清|超清|蓝光|标清|流畅)$"#
        guard label.range(of: pattern, options: .regularExpression) != nil else { return raw }
        return String(raw[..<dollar])
    }
    public static func resolve(_ value: String, base: URL?) -> String {
        guard !value.isEmpty else { return "" }
        return URL(string: value, relativeTo: base)?.absoluteURL.absoluteString ?? value
    }
    public static func resolveTemplate(_ value: String, base: URL?) -> String {
        resolve(value, base: base).replacingOccurrences(of: "%7B", with: "{").replacingOccurrences(of: "%7D", with: "}")
    }

    public static func configuration(_ data: Data, base: URL? = nil) throws -> Configuration {
        let payload = try ConfigurationPayload.decode(data)
        let text = String(data: payload, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if text.hasPrefix("<") {
            throw TVError.message("该地址返回的是网页或 XML 内容，不是 TVBox 配置。请填写页面提供的 JSON 配置或 M3U / TXT 列表地址。")
        }
        if text.hasPrefix("#EXTM3U"), text.contains("#EXT-X-") {
            throw TVError.message("这个地址是 HLS 视频清单，请用“打开视频”播放；导入源需要频道列表或 TVBox 配置。")
        }
        let isTXT = !text.hasPrefix("{") && !text.hasPrefix("[") && text.components(separatedBy: .newlines).contains { line in
            let parts = line.split(separator: ",", maxSplits: 1)
            guard parts.count == 2, !line.hasPrefix("#") else { return false }
            let link = parts[1].trimmingCharacters(in: .whitespaces)
            return ["http://", "https://", "rtsp://", "rtmp://"].contains(where: { link.hasPrefix($0) })
        }
        if text.hasPrefix("#EXTM3U") || isTXT {
            let channels = playlist(text, base: base)
            guard !channels.isEmpty else { throw TVError.message("直播列表没有可识别的频道地址。") }
            return Configuration(name: base?.deletingPathExtension().lastPathComponent ?? "直播列表", location: base?.absoluteString ?? "", channels: channels)
        }
        let object: Any
        do { object = try JSONSerialization.jsonObject(with: payload, options: [.fragmentsAllowed, .json5Allowed]) }
        catch { throw TVError.message("配置不是有效的 JSON / JSON5。可能使用了尚不支持的加密格式，或服务器返回了不完整的数据。") }
        guard let root = object as? [String: Any] else {
            throw TVError.message("配置必须是 TVBox JSON、M3U 或 TXT 直播列表。")
        }
        var result = Configuration(name: string(root["name"]).isEmpty ? "TVBox 配置" : string(root["name"]), location: base?.absoluteString ?? "")
        var keys = Set<String>()
        for (index, raw) in ((root["sites"] as? [[String: Any]]) ?? []).enumerated() {
            var key = string(raw["key"]); if key.isEmpty { key = "site-\(index)" }
            if keys.contains(key) { key += "-\(index)" }; keys.insert(key)
            let rawAPI = string(raw["api"])
            result.sites.append(Site(key: key, name: string(raw["name"]).isEmpty ? key : string(raw["name"]), type: Int(string(raw["type"])) ?? 1, api: rawAPI.hasPrefix("csp_") ? rawAPI : resolve(rawAPI, base: base), searchable: string(raw["searchable"]) != "0", headers: raw["header"] as? [String: String] ?? [:]))
        }
        for raw in (root["urls"] as? [[String: Any]]) ?? [] {
            let url = resolve(string(raw["url"]), base: base)
            if !url.isEmpty { result.subscriptions.append(Subscription(name: string(raw["name"]).isEmpty ? url : string(raw["name"]), url: url)) }
        }
        for raw in (root["lives"] as? [[String: Any]]) ?? [] {
            let name = string(raw["name"])
            var headers = raw["header"] as? [String: String] ?? [:]
            if !string(raw["ua"]).isEmpty { headers["User-Agent"] = string(raw["ua"]) }
            if !string(raw["referer"]).isEmpty { headers["Referer"] = string(raw["referer"]) }
            let epg = resolveTemplate(string(raw["epg"]).isEmpty ? string(root["epg"]) : string(raw["epg"]), base: base)
            let guide: LiveGuideInfo? = epg.isEmpty ? nil : LiveGuideInfo(url: epg)
            let url = resolve(string(raw["url"]), base: base)
            if !url.isEmpty { result.feeds.append(LiveFeed(name: name.isEmpty ? "直播订阅" : name, url: url, headers: headers, guide: guide)) }
            for channel in (raw["channels"] as? [[String: Any]]) ?? [] {
                let urls = (channel["urls"] as? [String] ?? []).map { resolve(liveAddress($0), base: base) }
                var info = guide ?? LiveGuideInfo()
                info.channelID = string(channel["tvg-id"]); info.channelName = string(channel["tvg-name"])
                if !string(channel["epg"]).isEmpty { info.url = resolveTemplate(string(channel["epg"]), base: base) }
                let source = string(channel["catchup-source"])
                if !source.isEmpty {
                    let mode = string(channel["catchup"]).isEmpty ? "default" : string(channel["catchup"])
                    info.catchup = CatchupTemplate(mode: mode, source: mode == "append" ? source : resolveTemplate(source, base: base), days: Double(string(channel["catchup-days"])) ?? 5)
                }
                if !urls.isEmpty { result.channels.append(Channel(name: string(channel["name"]), group: name.isEmpty ? "未分组" : name, urls: urls, headers: headers, guide: info.isEmpty ? nil : info)) }
            }
        }
        guard !result.sites.isEmpty || !result.feeds.isEmpty || !result.channels.isEmpty || !result.subscriptions.isEmpty else {
            throw TVError.message("没有找到 sites、lives 或 urls。请确认填写的是 TVBox 配置地址。")
        }
        return result
    }

    public static func playlist(_ text: String, base: URL? = nil, headers: [String: String] = [:], guide: LiveGuideInfo? = nil) -> [Channel] {
        var result: [Channel] = []
        var name = ""; var group = "未分组"; var logo = ""; var pending = headers
        var defaults = guide ?? LiveGuideInfo(), info = guide ?? LiveGuideInfo()
        var globalCatchup = "", globalSource = "", globalDays = "", globalCorrection = ""
        func attribute(_ line: String, _ key: String) -> String {
            guard let range = line.range(of: key + "=\"") else { return "" }
            return String(line[range.upperBound...].prefix { $0 != "\"" })
        }
        for raw in text.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty else { continue }
            if line.hasPrefix("#EXTM3U") {
                let epg = [attribute(line, "x-tvg-url"), attribute(line, "url-tvg")].first { !$0.isEmpty } ?? ""
                if !epg.isEmpty { defaults.url = resolveTemplate(epg.components(separatedBy: ",")[0], base: base) }
                globalCatchup = attribute(line, "catchup"); globalSource = attribute(line, "catchup-source"); globalDays = attribute(line, "catchup-days"); globalCorrection = attribute(line, "catchup-correction")
                info = defaults
            } else if line.hasPrefix("#EXTINF") {
                name = line.components(separatedBy: ",").dropFirst().joined(separator: ",")
                if name.isEmpty { name = attribute(line, "tvg-name") }
                let g = attribute(line, "group-title"); group = g.isEmpty ? "未分组" : g
                logo = resolve(attribute(line, "tvg-logo"), base: base); pending = headers
                info = defaults; info.channelID = attribute(line, "tvg-id"); info.channelName = attribute(line, "tvg-name")
                func inherited(_ key: String, _ fallback: String) -> String { let value = attribute(line, key); return value.isEmpty ? fallback : value }
                let mode = inherited("catchup", globalCatchup).lowercased(), source = inherited("catchup-source", globalSource)
                if !mode.isEmpty || !source.isEmpty {
                    let template = mode == "append" || source.hasPrefix("?") || source.hasPrefix("&") ? source : resolveTemplate(source, base: base)
                    info.catchup = CatchupTemplate(mode: mode.isEmpty ? "default" : mode, source: template, days: Double(inherited("catchup-days", globalDays)) ?? 5, correction: Double(inherited("catchup-correction", globalCorrection)) ?? 0)
                }
            } else if line.hasPrefix("#EXTGRP:") { group = String(line.dropFirst(8))
            } else if line.hasPrefix("#EXTVLCOPT:http-user-agent=") { pending["User-Agent"] = String(line.dropFirst("#EXTVLCOPT:http-user-agent=".count))
            } else if line.hasPrefix("#EXTVLCOPT:http-referrer=") { pending["Referer"] = String(line.dropFirst("#EXTVLCOPT:http-referrer=".count))
            } else if !line.hasPrefix("#") {
                if line.contains(",#genre#") { group = line.components(separatedBy: ",")[0]; continue }
                var link = line
                if let comma = line.firstIndex(of: ","), !line.hasPrefix("http"), !line.hasPrefix("rtsp") {
                    name = String(line[..<comma]); link = String(line[line.index(after: comma)...])
                }
                let parts = link.components(separatedBy: "|")
                if parts.count > 1 {
                    for pair in parts[1].components(separatedBy: "&") {
                        let kv = pair.split(separator: "=", maxSplits: 1).map(String.init)
                        if kv.count == 2 { pending[kv[0]] = kv[1].removingPercentEncoding ?? kv[1] }
                    }
                }
                let url = resolve(liveAddress(parts[0]), base: base)
                if let parsed = URL(string: url), ["http", "https", "rtsp", "rtmp", "file"].contains(parsed.scheme?.lowercased() ?? "") {
                    result.append(Channel(name: name.isEmpty ? "频道 \(result.count + 1)" : name, group: group, logo: logo, urls: [url], headers: pending, guide: info.isEmpty ? nil : info))
                }
                name = ""; logo = ""; pending = headers; info = defaults
            }
        }
        var seen = Set<String>()
        return result.filter { seen.insert($0.id).inserted }
    }

    public static func lines(names: String, urls: String, base: URL? = nil) -> [PlayLine] {
        let labels = names.components(separatedBy: "$$$")
        return urls.components(separatedBy: "$$$").enumerated().compactMap { index, group in
            let episodes = group.components(separatedBy: "#").enumerated().compactMap { offset, item -> Episode? in
                guard !item.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
                // URL query strings may contain '$'; split only the episode-name delimiter.
                let parts = item.split(separator: "$", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
                let url = parts.count == 2 ? parts[1] : parts[0]
                return Episode(name: parts.count == 2 ? parts[0] : "第 \(offset + 1) 集", url: resolve(url, base: base))
            }
            guard !episodes.isEmpty else { return nil }
            let label = index < labels.count && !labels[index].isEmpty ? labels[index] : "线路 \(index + 1)"
            return PlayLine(name: "\(label)\(labels.filter { $0 == label }.count > 1 ? " \(index + 1)" : "")", episodes: episodes)
        }
    }

    public static func catalog(_ data: Data, base: URL? = nil) throws -> Catalog {
        if String(data: data.prefix(200), encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("<") == true {
            let delegate = XMLCatalog(base: base); let parser = XMLParser(data: data); parser.delegate = delegate
            parser.shouldResolveExternalEntities = false
            guard parser.parse() else { throw TVError.message("XML 接口返回的数据无法解析。") }
            return Catalog(videos: delegate.videos, categories: delegate.categories, page: delegate.page, pageCount: delegate.pageCount)
        }
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw TVError.message("接口未返回 JSON 对象。") }
        guard root["list"] != nil || root["class"] != nil else { throw TVError.message("接口未返回影视列表：\(string(root["msg"]).prefix(160))") }
        let categories = ((root["class"] as? [[String: Any]]) ?? []).map { Category(id: string($0["type_id"]), name: string($0["type_name"])) }
        let videos = ((root["list"] as? [[String: Any]]) ?? []).compactMap { raw -> Video? in
            let id = string(raw["vod_id"]); guard !id.isEmpty else { return nil }
            return Video(id: id, title: string(raw["vod_name"]), poster: resolve(string(raw["vod_pic"]), base: base), note: string(raw["vod_remarks"]), year: string(raw["vod_year"]), area: string(raw["vod_area"]), director: string(raw["vod_director"]), actor: string(raw["vod_actor"]), summary: plainText(string(raw["vod_content"])), lines: lines(names: string(raw["vod_play_from"]), urls: string(raw["vod_play_url"]), base: base))
        }
        return Catalog(videos: videos, categories: categories, page: Int(string(root["page"])) ?? 1, pageCount: max(1, Int(string(root["pagecount"])) ?? 1))
    }

    public static func plainText(_ html: String) -> String {
        html.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "&nbsp;", with: " ").replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&quot;", with: "\"").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

private final class XMLCatalog: NSObject, XMLParserDelegate {
    let base: URL?
    var videos: [Video] = []; var categories: [Category] = []
    var page = 1; var pageCount = 1
    var stack: [String] = []; var buffer = ""; var fields: [String: String] = [:]
    var currentType = ""; var playNames: [String] = []; var playURLs: [String] = []; var flag = ""
    init(base: URL?) { self.base = base }
    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String]) {
        stack.append(name); buffer = ""
        if name == "list" { page = Int(attributes["page"] ?? "1") ?? 1; pageCount = max(1, Int(attributes["pagecount"] ?? "1") ?? 1) }
        if name == "video" { fields = [:]; playNames = []; playURLs = [] }
        if name == "ty" { currentType = attributes["id"] ?? "" }
        if name == "dd" { flag = attributes["flag"] ?? "线路 \(playNames.count + 1)" }
    }
    func parser(_ parser: XMLParser, foundCharacters string: String) { buffer += string }
    func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) { buffer += String(data: CDATABlock, encoding: .utf8) ?? "" }
    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        let value = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
        if name == "ty" { categories.append(Category(id: currentType, name: value)) }
        if name == "dd" { playNames.append(flag); playURLs.append(value) }
        if stack.contains("video") { fields[name] = value }
        if name == "video", let id = fields["id"], !id.isEmpty {
            videos.append(Video(id: id, title: fields["name"] ?? "", poster: Parser.resolve(fields["pic"] ?? "", base: base), note: fields["note"] ?? fields["state"] ?? "", year: fields["year"] ?? "", area: fields["area"] ?? "", director: fields["director"] ?? "", actor: fields["actor"] ?? "", summary: Parser.plainText(fields["des"] ?? ""), lines: Parser.lines(names: playNames.joined(separator: "$$$"), urls: playURLs.joined(separator: "$$$"), base: base)))
        }
        _ = stack.popLast(); buffer = ""
    }
}
