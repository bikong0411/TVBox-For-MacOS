import Combine
import Foundation
import TVBoxCore

struct TVSubscription: Codable, Identifiable {
    let url: URL
    let name: String
    var id: URL { url }
}

struct TVLiveFeed: Identifiable {
    let subscription: TVSubscription
    let feed: LiveFeed?
    let channels: [Channel]
    var id: String { subscription.url.absoluteString + "|" + (feed?.url ?? "") }
    var name: String { feed?.name ?? subscription.name }
}

struct TVBookmark: Codable, Identifiable {
    let siteID: String
    let videoID: String
    let title: String
    let episode: String
    let position: Double
    var id: String { siteID + "|" + videoID }
}

struct TVStream {
    let url: URL
    let userAgent: String?
}

struct TVPlaybackItem: Identifiable {
    let id = UUID()
    let title: String
    let streams: [TVStream]
    let hit: VODSearchHit?
    let line: PlayLine?
    let episode: Episode?
    let position: Double

    static func onDemand(_ hit: VODSearchHit?, title: String, line: PlayLine, episode: Episode, position: Double = 0) throws -> Self {
        let urls = try streams([episode.url], headers: hit?.source.site.headers ?? [:])
        return Self(title: title, streams: urls, hit: hit, line: line, episode: episode, position: position)
    }

    static func live(_ channel: Channel) throws -> Self {
        let urls = try streams(channel.urls, headers: channel.headers)
        return Self(title: channel.name, streams: urls, hit: nil, line: nil, episode: nil, position: 0)
    }

    private static func streams(_ addresses: [String], headers: [String: String]) throws -> [TVStream] {
        guard headers.keys.allSatisfy({ $0.caseInsensitiveCompare("User-Agent") == .orderedSame }) else {
            throw TelevisionError.unsupportedStreamHeaders
        }
        let agent = headers.first { $0.key.caseInsensitiveCompare("User-Agent") == .orderedSame }?.value
        let streams = addresses.compactMap(httpURL).map { TVStream(url: $0, userAgent: agent) }
        guard !streams.isEmpty else { throw TelevisionError.unsupportedStream }
        return streams
    }
}

enum TelevisionError: LocalizedError {
    case invalidAddress, unsupportedSource, unsupportedStream, unsupportedStreamHeaders, sourceNotLoaded, noEpisode, storageFull

    var errorDescription: String? {
        switch self {
        case .invalidAddress: return String(localized: "Enter a valid HTTP or HTTPS address.")
        case .unsupportedSource: return String(localized: "This subscription has no compatible XML, JSON, or live playlist. Android CSP sources require the Mac version.")
        case .unsupportedStream: return String(localized: "This stream cannot be opened on Apple TV. Try a compatible HLS or MP4 source.")
        case .unsupportedStreamHeaders: return String(localized: "This stream needs custom request headers that this Apple TV player cannot send.")
        case .sourceNotLoaded: return String(localized: "This source is unavailable. Reload it in Sources and try again.")
        case .noEpisode: return String(localized: "No playable stream was found for this episode.")
        case .storageFull: return String(localized: "There are too many saved source addresses. Remove an unused source and try again.")
        }
    }
}

func httpURL(_ value: String) -> URL? {
    guard let url = URL(string: value.trimmingCharacters(in: .whitespacesAndNewlines)),
          let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme),
          let host = url.host, !host.isEmpty else { return nil }
    return url
}

@MainActor final class TelevisionStore: ObservableObject {
    let service: TVService
    let availability = VODAvailability()
    var switchCache = VODPlaybackSearchCache()
    @Published private(set) var subscriptions: [TVSubscription]
    @Published private(set) var bookmarks: [TVBookmark]
    @Published private(set) var configurations: [URL: Configuration] = [:]
    @Published private(set) var restoring = false
    @Published var playback: TVPlaybackItem?
    @Published var alert: String?
    private let defaults: UserDefaults
    private var restored = false

    init(service: TVService = TVService(), defaults: UserDefaults = .standard) {
        self.service = service
        self.defaults = defaults
        subscriptions = Self.read(defaults, key: "sources.v1") ?? []
        bookmarks = Self.read(defaults, key: "progress.v1") ?? []
    }

    var vodSources: [VODSearchSource] {
        subscriptions.flatMap { source in
            (configurations[source.url]?.sites ?? []).map { site in
                var scoped = site
                scoped.key = source.url.absoluteString + "::" + site.key
                return VODSearchSource(subscription: source.name, site: scoped)
            }
        }
    }

    var liveFeeds: [TVLiveFeed] {
        subscriptions.flatMap { source in
            guard let config = configurations[source.url] else { return [TVLiveFeed]() }
            var feeds = config.feeds.map { TVLiveFeed(subscription: source, feed: $0, channels: []) }
            if !config.channels.isEmpty {
                feeds.append(TVLiveFeed(subscription: source, feed: nil, channels: config.channels))
            }
            return feeds
        }
    }

    func restore() async {
        guard !restored && !restoring else { return }
        restoring = true
        defer { restoring = false }
        let pending = subscriptions
        for offset in stride(from: 0, to: pending.count, by: 4) {
            guard !Task.isCancelled else { return }
            let batch = pending[offset..<min(offset + 4, pending.count)]
            await withTaskGroup(of: (URL, Configuration?).self) { group in
                for source in batch {
                    group.addTask { [service] in
                        let configuration = try? await service.configuration(at: source.url)
                        return (source.url, configuration.flatMap(Self.compatible))
                    }
                }
                for await (url, configuration) in group where !Task.isCancelled {
                    if subscriptions.contains(where: { $0.url == url }), configurations[url] == nil {
                        configurations[url] = configuration
                    }
                }
            }
        }
        restored = !Task.isCancelled
    }

    func importSource(_ address: String, name: String = "") async throws {
        guard let url = httpURL(address) else { throw TelevisionError.invalidAddress }
        let payload = try await service.configuration(at: url, reload: true)
        try Task.checkCancellation()
        guard let config = Self.compatible(payload) else { throw TelevisionError.unsupportedSource }
        let label = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let updated = TVSubscription(url: url, name: label.isEmpty ? config.name : label)
        var saved = subscriptions
        if let index = saved.firstIndex(where: { $0.url == url }) { saved[index] = updated }
        else { saved.append(updated) }
        let encoded = try JSONEncoder().encode(saved)
        guard encoded.count < 128_000 else { throw TelevisionError.storageFull }
        defaults.set(encoded, forKey: "sources.v1")
        subscriptions = saved
        configurations[url] = config
        switchCache = VODPlaybackSearchCache()
    }

    func remove(_ source: TVSubscription) {
        subscriptions.removeAll { $0.id == source.id }
        defaults.set(try? JSONEncoder().encode(subscriptions), forKey: "sources.v1")
        configurations.removeValue(forKey: source.url)
        switchCache = VODPlaybackSearchCache()
    }

    func detail(_ hit: VODSearchHit) async throws -> VODSearchHit {
        let video = hit.video.lines.isEmpty ? try await service.detail(video: hit.video, site: hit.source.site) : hit.video
        guard let playable = await availability.filter([video], site: hit.source.site).first else {
            throw TelevisionError.noEpisode
        }
        try Task.checkCancellation()
        return VODSearchHit(video: playable, source: hit.source)
    }

    func resume(_ bookmark: TVBookmark) async throws {
        guard let source = vodSources.first(where: { $0.id == bookmark.siteID }) else { throw TelevisionError.sourceNotLoaded }
        let summary = Video(id: bookmark.videoID, title: bookmark.title)
        let hit = try await detail(VODSearchHit(video: summary, source: source))
        let episode = Episode(name: bookmark.episode, url: "")
        guard let (line, index) = VODMatch.matchingEpisode(episode, in: hit.video, singleEpisode: true) else {
            throw TelevisionError.noEpisode
        }
        playback = try TVPlaybackItem.onDemand(hit, title: hit.video.title, line: line,
                                               episode: line.episodes[index], position: bookmark.position)
    }

    func saveProgress(_ playback: TVPlaybackItem, at seconds: Double) {
        guard let hit = playback.hit, let episode = playback.episode, seconds.isFinite, seconds >= 1 else { return }
        let bookmark = TVBookmark(siteID: hit.source.id, videoID: hit.video.id, title: hit.video.title,
                                  episode: episode.name, position: seconds)
        var recent = [bookmark] + bookmarks.filter { $0.id != bookmark.id }.prefix(49)
        while let data = try? JSONEncoder().encode(recent) {
            if data.count < 96_000 {
                defaults.set(data, forKey: "progress.v1")
                if bookmarks.first?.id != bookmark.id || bookmarks.first?.episode != bookmark.episode ||
                    abs((bookmarks.first?.position ?? 0) - bookmark.position) >= 1 {
                    bookmarks = recent
                }
                return
            }
            guard recent.count > 1 else { return }
            recent.removeLast()
        }
    }

    private nonisolated static func compatible(_ input: Configuration) -> Configuration? {
        var config = input
        config.sites = input.sites.filter { $0.supported && httpURL($0.api) != nil }
        config.feeds = input.feeds.filter { httpURL($0.url) != nil }
        config.channels = input.channels.filter { $0.urls.contains { httpURL($0) != nil } }
        config.subscriptions = input.subscriptions.filter { httpURL($0.url) != nil }
        return (config.sites.isEmpty && config.feeds.isEmpty && config.channels.isEmpty && config.subscriptions.isEmpty) ? nil : config
    }

    private static func read<T: Decodable>(_ defaults: UserDefaults, key: String) -> T? {
        defaults.data(forKey: key).flatMap { try? JSONDecoder().decode(T.self, from: $0) }
    }
}
