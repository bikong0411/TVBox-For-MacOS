import Foundation

public struct VODSearchSource: Identifiable, Hashable, Sendable {
    private struct RequestIdentity: Hashable {
        let type: Int
        let request: ProbeRequestKey
        let crawler: CSPDefinition?

        init(_ site: Site) {
            type = site.type
            request = ProbeRequestKey(kind: .vod, url: site.api, headers: site.headers)
            crawler = site.csp
        }
    }

    public let subscription: String
    public let site: Site
    public var id: String { site.id }
    public var name: String { subscription + " · " + site.name }

    public init(subscription: String, site: Site) {
        self.subscription = subscription
        self.site = site
    }

    public static func playbackAlternatives(in sources: [Self], excluding current: Site?) -> [Self] {
        var seen = Set<RequestIdentity>()
        if let current { seen.insert(RequestIdentity(current)) }
        return sources.filter { $0.id != current?.id && seen.insert(RequestIdentity($0.site)).inserted }
    }
}

public struct VODSearchHit: Identifiable, Hashable, Sendable {
    public let video: Video
    public let source: VODSearchSource
    public var id: String { source.id + "|" + video.id }

    public init(video: Video, source: VODSearchSource) {
        self.video = video
        self.source = source
    }
}

public struct VODPlaybackSearch: Sendable {
    public let video: Video
    public let episode: Episode
    public let singleEpisode: Bool

    public init(video: Video, episode: Episode, singleEpisode: Bool) {
        self.video = video
        self.episode = episode
        self.singleEpisode = singleEpisode
    }
}

public struct VODPlaybackSearchCache {
    public struct Key: Hashable {
        private let siteID: String
        private let videoID: String
        private let title: String
        private let episode: String
        private let singleEpisode: Bool

        public init(siteID: String, search: VODPlaybackSearch) {
            self.siteID = siteID
            videoID = search.video.id
            title = VODMatch.titleKey(search.video)
            episode = search.episode.name
            singleEpisode = search.singleEpisode
        }
    }

    public struct Results {
        public var checked: [String: Site] = [:]
        public var pages: [[VODSearchHit]] = []
        public var rejected: Set<String> = []

        public init() {}

        public func retaining(_ sources: [VODSearchSource]) -> Results {
            let sites = Dictionary(sources.map { ($0.id, $0.site) }, uniquingKeysWith: { first, _ in first })
            var result = self
            result.checked = checked.filter { sites[$0.key] == $0.value }
            result.pages = pages.map { page in page.filter { result.checked[$0.source.id] == $0.source.site } }
                .filter { !$0.isEmpty }
            result.rejected.formIntersection(result.pages.flatMap { $0.map(\.id) })
            return result
        }
    }

    private var entries: [Key: (results: Results, expires: Date)] = [:]

    public init() {}

    public func results(for key: Key, now: Date = Date()) -> Results? {
        guard let entry = entries[key], entry.expires > now else { return nil }
        return entry.results
    }

    public mutating func save(_ results: Results, for key: Key, now: Date = Date()) {
        entries = entries.filter { $0.value.expires > now }
        if entries[key] == nil, entries.count >= 16,
           let oldest = entries.min(by: { $0.value.expires < $1.value.expires }) {
            entries.removeValue(forKey: oldest.key)
        }
        entries[key] = (results, now.addingTimeInterval(120))
    }
}

public enum VODMatch {
    public static func titleKey(_ video: Video) -> String { normalized(video.title) + "|" + year(video) }

    public static func sameTitle(_ lhs: Video, _ rhs: Video) -> Bool {
        let title = normalized(lhs.title)
        guard !title.isEmpty, title == normalized(rhs.title) else { return false }
        let left = year(lhs), right = year(rhs)
        return left.isEmpty || right.isEmpty || left == right
    }

    public static func topPlaybackSources(for video: Video, episode: Episode, singleEpisode: Bool,
                                          from hits: [VODSearchHit]) -> [VODSearchHit] {
        let currentYear = year(video)
        let ranked = hits.compactMap { hit -> (hit: VODSearchHit, priority: Int)? in
            guard sameTitle(video, hit.video) else { return nil }
            let hasEpisode = matchingEpisode(episode, in: hit.video, singleEpisode: singleEpisode) != nil
            guard hasEpisode || hit.video.lines.isEmpty else { return nil }
            let sameYear = !currentYear.isEmpty && currentYear == year(hit.video)
            return (hit, (sameYear ? 2 : 0) + (hasEpisode ? 1 : 0))
        }.sorted {
            (-$0.priority, $0.hit.source.site.name, $0.hit.id) < (-$1.priority, $1.hit.source.site.name, $1.hit.id)
        }
        var shown = Set<String>()
        return Array(ranked.map(\.hit).filter { shown.insert($0.source.id).inserted }.prefix(10))
    }

    public static func matchingEpisode(_ episode: Episode, in video: Video, singleEpisode: Bool) -> (PlayLine, Int)? {
        let name = normalized(episode.name)
        let number = episodeNumber(episode.name)
        for line in video.lines {
            let exact = line.episodes.indices.filter { !name.isEmpty && normalized(line.episodes[$0].name) == name }
            if exact.count == 1 { return (line, exact[0]) }
            if let number {
                let numbered = line.episodes.indices.filter { episodeNumber(line.episodes[$0].name) == number }
                if numbered.count == 1 { return (line, numbered[0]) }
            }
        }
        let movieLabels: Set<String> = ["正片", "完整版", "播放", "movie", "full", "main", "高清", "hd", normalized(video.title)]
        if singleEpisode, movieLabels.contains(name), video.lines.allSatisfy({ $0.episodes.count == 1 }),
           let line = video.lines.first, let target = line.episodes.first, movieLabels.contains(normalized(target.name)) {
            return (line, 0)
        }
        return nil
    }

    private static func normalized(_ value: String) -> String {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
            .filter { $0.isLetter || $0.isNumber }
    }
    private static func year(_ video: Video) -> String {
        let value = video.year.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.count == 4 && Int(value) != nil ? value : ""
    }
    private static func episodeNumber(_ value: String) -> Int? {
        let value = normalized(value)
        let trimmed = value.replacingOccurrences(of: #"^(?:第|episode|ep|e)|[集话話期]$"#, with: "", options: .regularExpression)
        return Int(trimmed)
    }
}

public extension TVService {
    /// Look for alternatives in batches of ten, publishing results as each
    /// interface finishes. A batch with a match ends the search.
    func searchPlaybackSources(_ sources: [VODSearchSource], for playback: VODPlaybackSearch,
                               availability: VODAvailability, hasResults: @MainActor () -> Bool,
                               onSource: @MainActor (VODSearchSource, [VODSearchHit]) -> Void) async {
        let batchSize = 10
        for start in stride(from: 0, to: sources.count, by: batchSize) {
            guard !Task.isCancelled else { return }
            let batch = sources[start..<min(start + batchSize, sources.count)]
            await searchAcrossSources(Array(batch), query: playback.video.title, availability: availability, matching: playback) { source, hits, _ in
                onSource(source, hits)
            }
            if await hasResults() { return }
        }
    }

    /// Search the first result page of each interface, publishing as it finishes.
    func searchAcrossSources(_ sources: [VODSearchSource], query: String, availability: VODAvailability,
                              matching playback: VODPlaybackSearch? = nil,
                              onSource: @MainActor (VODSearchSource, [VODSearchHit], Bool) -> Void) async {
        let candidates = sources.filter { $0.site.searchable && supports($0.site) }
        let maxConcurrentSources = 8
        await withTaskGroup(of: (VODSearchSource, [VODSearchHit], Bool).self) { group in
            var next = candidates.makeIterator()
            func enqueue(_ source: VODSearchSource) {
                group.addTask {
                    do {
                        let catalog = try await self.catalog(site: source.site, search: query, timeout: playback == nil ? 25 : 5)
                        let checked: [Video]
                        if let playback {
                            checked = await self.playbackCandidate(in: catalog.videos, site: source.site,
                                                                   matching: playback, availability: availability).map { [$0] } ?? []
                        } else {
                            checked = await self.checkedCatalogVideos(catalog.videos, site: source.site, availability: availability, probeLimit: 4)
                        }
                        return (source, checked.map { VODSearchHit(video: $0, source: source) }, true)
                    } catch {
                        return (source, [], false)
                    }
                }
            }
            for _ in 0..<min(maxConcurrentSources, candidates.count) {
                if let source = next.next() { enqueue(source) }
            }
            while let (source, hits, success) = await group.next() {
                guard !Task.isCancelled else { group.cancelAll(); break }
                await onSource(source, hits, success)
                if let source = next.next() { enqueue(source) }
            }
        }
    }

    private func playbackCandidate(in videos: [Video], site: Site, matching playback: VODPlaybackSearch,
                                   availability: VODAvailability) async -> Video? {
        let matchingTitle = videos.filter { VODMatch.sameTitle(playback.video, $0) }
        let titleKey = VODMatch.titleKey(playback.video)
        let exactYear = matchingTitle.filter { VODMatch.titleKey($0) == titleKey }
        let otherYear = matchingTitle.filter { VODMatch.titleKey($0) != titleKey }
        for video in exactYear + otherYear {
            guard !Task.isCancelled else { return nil }
            let loaded = video.lines.isEmpty ? (try? await detail(video: video, site: site, timeout: 5)) : video
            guard let loaded, VODMatch.sameTitle(playback.video, loaded),
                  var candidate = await availability.filter([loaded], site: site, probeLimit: 0).first else { continue }
            while !Task.isCancelled,
                  let (line, index) = VODMatch.matchingEpisode(playback.episode, in: candidate, singleEpisode: playback.singleEpisode),
                  let lineIndex = candidate.lines.firstIndex(of: line) {
                var sample = candidate
                sample.lines = [PlayLine(name: line.name, episodes: [line.episodes[index]])]
                if !(await availability.filter([sample], site: site, probeLimit: 1)).isEmpty { return candidate }
                candidate.lines[lineIndex].episodes.remove(at: index)
                if candidate.lines[lineIndex].episodes.isEmpty { candidate.lines.remove(at: lineIndex) }
            }
        }
        return nil
    }
}
