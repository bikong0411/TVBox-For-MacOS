import Foundation

public struct Site: Codable, Identifiable, Hashable, Sendable {
    public var key: String
    public var name: String
    public var type: Int
    public var api: String
    public var searchable: Bool
    public var headers: [String: String]
    public var csp: CSPDefinition?
    public var id: String { key }
    public var supported: Bool { [0, 1].contains(type) && URL(string: api)?.host != nil }
    public var requiresCSP: Bool { type == 3 && csp != nil }
    /// Selectable describes a recognized protocol, not the availability of an
    /// upstream service or proof that every method of a third-party spider works.
    public var selectable: Bool { supported || requiresCSP }
    public var format: String {
        switch type { case 0: return "XML"; case 1: return "JSON"; case 3: return requiresCSP ? "Java / CSP" : "爬虫 / JAR"; case 4: return "远程爬虫"; default: return "类型 \(type)" }
    }
    public init(key: String, name: String, type: Int, api: String, searchable: Bool = true, headers: [String: String] = [:], csp: CSPDefinition? = nil) {
        self.key = key; self.name = name; self.type = type; self.api = api; self.searchable = searchable; self.headers = headers; self.csp = csp
    }
}

public struct LiveFeed: Codable, Identifiable, Hashable, Sendable {
    public var name: String
    public var url: String
    public var headers: [String: String]
    public var guide: LiveGuideInfo?
    public var id: String { url }
    public init(name: String, url: String, headers: [String: String] = [:], guide: LiveGuideInfo? = nil) { self.name = name; self.url = url; self.headers = headers; self.guide = guide }
}

public struct Channel: Codable, Identifiable, Hashable, Sendable {
    public var name: String
    public var group: String
    public var logo: String
    public var urls: [String]
    public var headers: [String: String]
    public var guide: LiveGuideInfo?
    public var id: String { [group, name, urls.first ?? "", headers.sorted { $0.key < $1.key }.map { $0.key + ":" + $0.value }.joined(separator: "\n")].joined(separator: "|") }
    public init(name: String, group: String = "未分组", logo: String = "", urls: [String], headers: [String: String] = [:], guide: LiveGuideInfo? = nil) {
        self.name = name; self.group = group; self.logo = logo; self.urls = urls; self.headers = headers; self.guide = guide
    }
}

public struct Subscription: Codable, Identifiable, Hashable, Sendable {
    public var name: String
    public var url: String
    public var id: String { url }
}

public struct Configuration: Codable, Equatable, Sendable {
    public var name: String
    public var location: String
    public var sites: [Site]
    public var feeds: [LiveFeed]
    public var channels: [Channel]
    public var subscriptions: [Subscription]
    public init(name: String = "我的配置", location: String = "", sites: [Site] = [], feeds: [LiveFeed] = [], channels: [Channel] = [], subscriptions: [Subscription] = []) {
        self.name = name; self.location = location; self.sites = sites; self.feeds = feeds; self.channels = channels; self.subscriptions = subscriptions
    }
}

public struct Category: Codable, Identifiable, Hashable, Sendable {
    public var id: String
    public var name: String
    public init(id: String, name: String) { self.id = id; self.name = name }
}

public struct Episode: Codable, Identifiable, Hashable, Sendable {
    public var name: String
    public var url: String
    public var id: String { name + "|" + url }
    public init(name: String, url: String) { self.name = name; self.url = url }
}

public struct PlayLine: Codable, Identifiable, Hashable, Sendable {
    public var name: String
    public var episodes: [Episode]
    public var id: String { name }
    public init(name: String, episodes: [Episode]) { self.name = name; self.episodes = episodes }
}

public struct Video: Codable, Identifiable, Hashable, Sendable {
    public var id: String
    public var title: String
    public var poster: String
    public var note: String
    public var year: String
    public var area: String
    public var director: String
    public var actor: String
    public var summary: String
    public var lines: [PlayLine]
    public init(id: String, title: String, poster: String = "", note: String = "", year: String = "", area: String = "", director: String = "", actor: String = "", summary: String = "", lines: [PlayLine] = []) {
        self.id = id; self.title = title; self.poster = poster; self.note = note; self.year = year; self.area = area; self.director = director; self.actor = actor; self.summary = summary; self.lines = lines
    }
}

public struct Catalog {
    public var videos: [Video]
    public var categories: [Category]
    public var page: Int
    public var pageCount: Int
    public init(videos: [Video], categories: [Category] = [], page: Int = 1, pageCount: Int = 1) {
        self.videos = videos; self.categories = categories; self.page = page; self.pageCount = pageCount
    }
}

public struct LibraryEntry: Codable, Identifiable, Sendable {
    public var video: Video
    public var site: Site?
    public var episode: Episode?
    public var position: Double
    public var updated: Date
    public var id: String { (site?.key ?? "demo") + "|" + video.id }
    public init(video: Video, site: Site?, episode: Episode? = nil, position: Double = 0) {
        self.video = video; self.site = site; self.episode = episode; self.position = position; updated = Date()
    }
}

public enum TVError: LocalizedError {
    case message(String)
    public var errorDescription: String? { if case .message(let s) = self { return s }; return nil }
}

public enum Demo {
    public static let videos: [Video] = [
        Video(id: "sintel", title: "Sintel", note: "开放电影 · 官方预告", year: "2010", area: "荷兰", director: "Colin Levy", summary: "Blender Foundation 开放电影预告片。年轻的 Sintel 踏上一段寻找小龙的旅程。", lines: [PlayLine(name: "Blender 官方", episodes: [Episode(name: "预告片", url: "https://download.blender.org/durian/trailer/sintel_trailer-480p.mp4")])])
    ]
}
