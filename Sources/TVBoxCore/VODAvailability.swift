import Foundation

/// Suppress only known unusable addresses. Authentication, timeouts and
/// opaque crawler IDs remain selectable, since a probe cannot judge them.
public actor VODAvailability {
    private struct Entry { let unavailable: Bool; let expires: Date }
    private struct CrawlerEpisode: Hashable { let site: Site; let line: String; let address: String }
    private struct CatalogTitle: Hashable { let site: Site; let id: String }
    private let prober: NetworkProber
    private var cache: [ProbeRequestKey: Entry] = [:]
    private var pending = Set<ProbeRequestKey>()
    private var crawlerFailures: [CrawlerEpisode: Date] = [:]
    private var catalogFailures: [CatalogTitle: Date] = [:]

    public init(prober: NetworkProber = NetworkProber()) { self.prober = prober }

    func filterCachedCatalogFailures(_ videos: [Video], site: Site) -> [Video] {
        let now = Date()
        guard !catalogFailures.isEmpty else { return videos }
        return videos.filter { video in
            !video.lines.isEmpty || (catalogFailures[CatalogTitle(site: site, id: video.id)] ?? .distantPast) <= now
        }
    }

    func rememberCatalogChecks(site: Site, resolved: Set<String>, visible: Set<String>) {
        let expires = Date().addingTimeInterval(120)
        for id in resolved {
            let key = CatalogTitle(site: site, id: id)
            catalogFailures[key] = visible.contains(id) ? nil : expires
        }
        if catalogFailures.count > 512 {
            let newest = catalogFailures.sorted { $0.value > $1.value }.prefix(512)
            catalogFailures = Dictionary(uniqueKeysWithValues: newest.map { ($0.key, $0.value) })
        }
    }

    public func markCrawlerUnavailable(site: Site, line: PlayLine, episode: Episode) {
        crawlerFailures = crawlerFailures.filter { $0.value > Date() }
        if crawlerFailures.count >= 512, let oldest = crawlerFailures.min(by: { $0.value < $1.value }) {
            crawlerFailures.removeValue(forKey: oldest.key)
        }
        let key = CrawlerEpisode(site: site, line: line.name, address: episode.url)
        crawlerFailures[key] = Date().addingTimeInterval(120)
    }

    public func filter(_ videos: [Video], site: Site?, probeLimit: Int = 8) async -> [Video] {
        let normalized = videos.map { video -> Video in
            var video = video
            video.lines = usableLines(video.lines, site: site)
            return video
        }
        let headers = site?.headers ?? [:]
        // A separate probe cannot reproduce arbitrary credentials or headers.
        if site?.requiresCSP != true && headers.keys.allSatisfy({ ["user-agent", "referer", "referrer"].contains($0.lowercased()) }) {
            var seen = Set<URL>()
            // Check one episode per title first, then spend any remaining
            // budget on other episodes. A long show cannot starve the grid.
            let episodes = normalized.map { $0.lines.flatMap(\.episodes) }
            let ordered = episodes.compactMap(\.first) + episodes.flatMap { $0.dropFirst() }
            var selected: [URL] = []
            for episode in ordered {
                if selected.count >= probeLimit { break }
                guard let url = URL(string: episode.url), ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
                      seen.insert(url).inserted, cached(url, headers: headers) == nil else { continue }
                selected.append(url)
            }
            for offset in stride(from: 0, to: selected.count, by: 4) {
                guard !Task.isCancelled else { break }
                let batch = selected[offset..<min(offset + 4, selected.count)]
                await withTaskGroup(of: Void.self) { group in
                    for url in batch { group.addTask { await self.check(url, headers: headers) } }
                }
            }
        }
        return zip(videos, normalized).compactMap { original, video in
            guard !original.lines.isEmpty else { return video } // Catalog may omit detail.
            var result = video
            result.lines = usableLines(video.lines, site: site)
            return result.lines.isEmpty ? nil : result
        }
    }

    private func usableLines(_ lines: [PlayLine], site: Site?) -> [PlayLine] {
        lines.compactMap { line in
            let episodes = line.episodes.filter { episode in
                if let site, site.requiresCSP {
                    let key = CrawlerEpisode(site: site, line: line.name, address: episode.url)
                    return !episode.url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
                        (crawlerFailures[key] ?? .distantPast) <= Date()
                }
                guard let url = URL(string: episode.url), let scheme = url.scheme?.lowercased() else { return false }
                if url.isFileURL { return FileManager.default.fileExists(atPath: url.path) }
                return ["http", "https", "rtsp", "rtmp"].contains(scheme) && url.host?.isEmpty == false &&
                    cached(url, headers: site?.headers ?? [:]) != true
            }
            return episodes.isEmpty ? nil : PlayLine(name: line.name, episodes: episodes)
        }
    }

    private func cached(_ url: URL, headers: [String: String]) -> Bool? {
        let key = ProbeRequestKey(kind: .vod, url: url.absoluteString, headers: headers)
        guard let entry = cache[key], entry.expires > Date() else { return nil }
        return entry.unavailable
    }

    private func check(_ url: URL, headers: [String: String]) async {
        let key = ProbeRequestKey(kind: .vod, url: url.absoluteString, headers: headers)
        let queueDeadline = Date().addingTimeInterval(2.5)
        while pending.count >= 4 || pending.contains(key) {
            guard cached(url, headers: headers) == nil, Date() < queueDeadline else { return }
            do { try await Task.sleep(nanoseconds: 50_000_000) }
            catch { return }
        }
        guard !Task.isCancelled, cached(url, headers: headers) == nil else { return }
        pending.insert(key)
        defer { pending.remove(key) }
        let status = await prober.mediaStatus(url: url, headers: headers)
        guard !Task.isCancelled else { return }
        let unavailable = status == 404 || status == 410
        let ttl: TimeInterval = unavailable || (200..<300).contains(status ?? 0) ? 120 : 20
        if cache.count >= 1024 { cache = cache.filter { $0.value.expires > Date() } }
        if cache.count >= 1024, let oldest = cache.min(by: { $0.value.expires < $1.value.expires }) {
            cache.removeValue(forKey: oldest.key)
        }
        cache[key] = Entry(unavailable: unavailable, expires: Date().addingTimeInterval(ttl))
    }
}
