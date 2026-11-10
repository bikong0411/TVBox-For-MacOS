import Foundation

public struct LiveGuideInfo: Codable, Hashable, Sendable {
    public var url: String
    public var channelID: String
    public var channelName: String
    public var catchup: CatchupTemplate?
    public init(url: String = "", channelID: String = "", channelName: String = "", catchup: CatchupTemplate? = nil) {
        self.url = url; self.channelID = channelID; self.channelName = channelName; self.catchup = catchup
    }
    public var isEmpty: Bool { url.isEmpty && channelID.isEmpty && channelName.isEmpty && catchup == nil }
}

public struct Programme: Identifiable, Hashable, Sendable {
    public var channelID: String
    public var title: String
    public var summary: String
    public var start: Date
    public var end: Date?
    public var catchupID: String
    public var id: String { channelID + "|" + String(start.timeIntervalSince1970) + "|" + title }
    public init(channelID: String, title: String, summary: String = "", start: Date, end: Date? = nil, catchupID: String = "") {
        self.channelID = channelID; self.title = title; self.summary = summary; self.start = start; self.end = end; self.catchupID = catchupID
    }
    public func isOnAir(at now: Date) -> Bool { start <= now && end.map { now < $0 } == true }
}

public struct CatchupTemplate: Codable, Hashable, Sendable {
    public var mode: String
    public var source: String
    public var days: Double
    public var correction: Double
    public init(mode: String = "default", source: String, days: Double = 5, correction: Double = 0) {
        self.mode = mode; self.source = source; self.days = days; self.correction = correction
    }
    /// Only explicit default / append / shift templates are supported. Unknown
    /// provider modes never fall back to playing an unrelated live URL.
    public func playbackURL(programme: Programme, liveURL: String, now: Date = Date(), timeZone: TimeZone = .current) -> URL? {
        let mode = mode.lowercased()
        guard ["default", "append", "shift"].contains(mode), days.isFinite, days > 0, correction.isFinite,
              programme.start < now, programme.start >= now.addingTimeInterval(-days * 86400),
              let end = programme.end, end > programme.start else { return nil }
        var value = source
        if mode == "shift" && value.isEmpty { value = (liveURL.contains("?") ? "&" : "?") + "utc={utc}&lutc={lutc}" }
        guard !value.isEmpty else { return nil }
        let correctedStart = programme.start.addingTimeInterval(correction * 3600)
        let correctedEnd = end.addingTimeInterval(correction * 3600)
        let interval = end.timeIntervalSince(programme.start)
        let numbers = [correctedStart.timeIntervalSince1970, correctedEnd.timeIntervalSince1970, now.timeIntervalSince1970, interval]
        guard numbers.allSatisfy({ $0.isFinite && $0 > Double(Int.min) && $0 < Double(Int.max) }) else { return nil }
        let duration = Int(interval)
        let tokens: [String: String] = ["utc": String(Int(correctedStart.timeIntervalSince1970)), "start": String(Int(correctedStart.timeIntervalSince1970)),
            "utcend": String(Int(correctedEnd.timeIntervalSince1970)), "end": String(Int(correctedEnd.timeIntervalSince1970)),
            "lutc": String(Int(now.timeIntervalSince1970)), "now": String(Int(now.timeIntervalSince1970)), "timestamp": String(Int(now.timeIntervalSince1970)),
            "duration": String(duration), "catchup-id": programme.catchupID]
        // Replace longest spellings first so ${start} does not retain '$'.
        for (key, replacement) in tokens { value = value.replacingOccurrences(of: "${" + key + "}", with: replacement).replacingOccurrences(of: "{" + key + "}", with: replacement) }
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.calendar = Calendar(identifier: .gregorian); formatter.timeZone = timeZone
        for (key, format) in [("Y", "yyyy"), ("m", "MM"), ("d", "dd"), ("H", "HH"), ("M", "mm"), ("S", "ss")] {
            formatter.dateFormat = format; value = value.replacingOccurrences(of: "{" + key + "}", with: formatter.string(from: correctedStart))
        }
        guard !value.contains("{"), !value.contains("}"), !value.contains("%7B"), !value.contains("%7b") else { return nil }
        if mode == "append" || mode == "shift" { value = liveURL + value }
        guard let url = URL(string: value), ["http", "https"].contains(url.scheme?.lowercased() ?? ""), url.host != nil else { return nil }
        return url
    }
}

public struct ProgrammeGuide: Sendable {
    public var programmes: [String: [Programme]]
    public var names: [String: [String]]
    var isJSON = false
    public func programmes(for channel: Channel, day: Date, calendar: Calendar = .current) -> [Programme] {
        let info = channel.guide
        // An explicit tvg-id is authoritative. Name matching is exact (case folded)
        // and only allowed when a single XMLTV channel owns that name.
        let candidates = [info?.channelName ?? "", channel.name].filter { !$0.isEmpty }
        var id = info?.channelID ?? ""
        if id.isEmpty {
            for name in candidates {
                if programmes[name] != nil { id = name; break }
                let matches = names.filter { $0.value.contains { $0.caseInsensitiveCompare(name) == .orderedSame } }.map(\.key)
                if matches.count == 1 { id = matches[0]; break }
            }
        }
        let range = calendar.dateInterval(of: .day, for: day)
        return (programmes[id] ?? []).filter { item in
            guard let range else { return true }; return item.start < range.end && (item.end.map { $0 > range.start } ?? (item.start >= range.start))
        }
    }
    public static func parse(_ data: Data, day: Date, timeZone: TimeZone = .current) throws -> ProgrammeGuide {
        if data.first(where: { ![9, 10, 13, 32].contains($0) }) == 123 { return try parseJSON(data, day: day, timeZone: timeZone) }
        let delegate = XMLProgrammeGuide(); let parser = XMLParser(data: data); parser.delegate = delegate; parser.shouldResolveExternalEntities = false
        guard parser.parse(), delegate.isTV else { throw TVError.message("节目单不是有效的 XMLTV 或 TVBox JSON 格式。") }
        return normalized(delegate.programmes, names: delegate.names)
    }
    private static func normalized(_ input: [String: [Programme]], names: [String: [String]]) -> ProgrammeGuide {
        var result = input
        for (id, items) in input {
            var seen = Set<String>(); var ordered = items.filter { seen.insert($0.id).inserted }.sorted { $0.start < $1.start }
            for index in ordered.indices where ordered[index].end == nil && index + 1 < ordered.count { ordered[index].end = ordered[index + 1].start }
            result[id] = ordered
        }
        return ProgrammeGuide(programmes: result, names: names)
    }
    private static func parseJSON(_ data: Data, day: Date, timeZone: TimeZone) throws -> ProgrammeGuide {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any], let list = root["epg_data"] as? [[String: Any]] else { throw TVError.message("节目单 JSON 缺少 epg_data。") }
        let id = root["channel_name"] as? String ?? ""
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.timeZone = timeZone; formatter.dateFormat = "yyyy-MM-dd"
        let date = root["date"] as? String ?? formatter.string(from: day)
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        var items: [Programme] = []
        for raw in list {
            guard let title = raw["title"] as? String, !title.isEmpty, let startText = raw["start"] as? String,
                  let start = formatter.date(from: date + " " + startText) else { continue }
            var end = (raw["end"] as? String).flatMap { formatter.date(from: date + " " + ($0 == "24:00" ? "00:00" : $0)) }
            if let stop = end, stop <= start { var calendar = Calendar(identifier: .gregorian); calendar.timeZone = timeZone; end = calendar.date(byAdding: .day, value: 1, to: stop) }
            items.append(Programme(channelID: id, title: title, summary: raw["desc"] as? String ?? "", start: start, end: end))
        }
        var guide = normalized([id: items], names: [id: [id]]); guide.isJSON = true; return guide
    }
}

private final class XMLProgrammeGuide: NSObject, XMLParserDelegate {
    var programmes: [String: [Programme]] = [:], names: [String: [String]] = [:]
    var isTV = false
    private var channel: String?, item: Programme?, text = "", stack: [String] = []
    private let formatter: DateFormatter = { let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = TimeZone(secondsFromGMT: 0); return f }()
    private func date(_ value: String?) -> Date? {
        guard let value else { return nil }; let parts = value.split(separator: " ").map(String.init)
        guard let digits = parts.first, [12, 14].contains(digits.count) else { return nil }
        formatter.dateFormat = digits.count == 14 ? "yyyyMMddHHmmss Z" : "yyyyMMddHHmm Z"
        return formatter.date(from: digits + " " + (parts.count > 1 ? parts[1] : "+0000"))
    }
    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String]) {
        stack.append(name); text = ""
        if stack.count == 1 { isTV = name == "tv" }
        if name == "channel" { channel = attributes["id"] }
        if name == "programme", let id = attributes["channel"], let start = date(attributes["start"]) { item = Programme(channelID: id, title: "", start: start, end: date(attributes["stop"]), catchupID: attributes["catchup-id"] ?? "") }
    }
    func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }
    func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) { text += String(data: CDATABlock, encoding: .utf8) ?? "" }
    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if name == "display-name", let channel { names[channel, default: []].append(value) }
        if name == "channel" { channel = nil }
        if name == "title", item?.title.isEmpty == true { item?.title = value }
        if name == "desc", item?.summary.isEmpty == true { item?.summary = value }
        if name == "programme" { if let item, !item.title.isEmpty, item.end.map({ $0 > item.start }) ?? true { programmes[item.channelID, default: []].append(item) }; item = nil }
        _ = stack.popLast(); text = ""
    }
}

/// Isolated parsing and a small response cache keep large guides off the UI
/// thread. A single source response is reused across its channels for 5 minutes.
public actor ProgrammeGuideService {
    private struct Entry { var guide: ProgrammeGuide; var date: Date }
    private struct Key: Hashable { var url: URL; var headers: [String: String] }
    private var cache: [Key: Entry] = [:]
    private let service: TVService
    public init(service: TVService = TVService()) { self.service = service }
    public func programmes(channel: Channel, day: Date) async throws -> [Programme] {
        guard let info = channel.guide, !info.url.isEmpty else { return [] }
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.dateFormat = "yyyy-MM-dd"
        let escapedName = (info.channelName.isEmpty ? channel.name : info.channelName).addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "&=?/#%+"))) ?? ""
        let value = info.url.replacingOccurrences(of: "{name}", with: escapedName).replacingOccurrences(of: "{date}", with: formatter.string(from: day))
        guard !value.contains("{"), let url = URL(string: value), ["http", "https", "file"].contains(url.scheme?.lowercased() ?? "") else { throw TVError.message("节目单地址暂不支持。") }
        let key = Key(url: url, headers: channel.headers)
        let guide: ProgrammeGuide
        if let entry = cache[key], Date().timeIntervalSince(entry.date) < 300 { guide = entry.guide }
        else {
            let data = try await service.data(at: url, headers: channel.headers)
            try Task.checkCancellation()
            guide = try ProgrammeGuide.parse(data, day: day)
            if cache.count >= 4 { cache.removeAll() }
            cache[key] = Entry(guide: guide, date: Date())
        }
        try Task.checkCancellation()
        // JSON APIs identify the requested channel with their canonical name.
        if guide.isJSON, guide.programmes.count == 1 {
            var requestChannel = channel; requestChannel.guide?.channelID = guide.programmes.keys.first ?? ""
            return guide.programmes(for: requestChannel, day: day)
        }
        return guide.programmes(for: channel, day: day)
    }
}
