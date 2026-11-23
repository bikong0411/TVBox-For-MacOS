import Foundation
import Testing
@testable import TVBoxCore

@Suite struct VODSearchTests {
    private let fixture = "https://media.example.invalid"

    private func video(_ title: String = "Example Show", year: String = "2024", urls: [String] = []) -> Video {
        Video(id: title, title: title, year: year, lines: urls.isEmpty ? [] : [PlayLine(name: "HD", episodes:
            urls.enumerated().map { Episode(name: "第\($0.offset + 1)集", url: $0.element) })])
    }

    private func availability() -> VODAvailability {
        VODAvailability(prober: NetworkProber(configuration: {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [VODSearchProtocol.self]
            return configuration
        }))
    }

    @Test func hidesOnlyDefiniteFailuresAndUnsupportedProtocols() async {
        let checker = availability()
        let unavailable = video("Gone", urls: [fixture + "/gone", fixture + "/missing", "ftp://invalid.example/video"])
        let mixed = video("Mixed", urls: [fixture + "/missing", fixture + "/denied", fixture + "/timeout", fixture + "/temporary", fixture + "/ready"])
        let unspecified = video("Metadata only")
        let visible = await checker.filter([unavailable, mixed, unspecified], site: nil)
        #expect(visible.map(\.title) == ["Mixed", "Metadata only"])
        #expect(visible.first?.lines.first?.episodes.map(\.url) ==
                [fixture + "/denied", fixture + "/timeout", fixture + "/temporary", fixture + "/ready"])
        #expect(await checker.filter([unavailable], site: nil, probeLimit: 0).isEmpty)
    }

    @Test func crawlerFailuresAreScopedToAnInterfaceAndLine() async throws {
        let checker = availability()
        let definition = try CSPDefinition(component: CSPComponent("https://fixture.invalid/f.jar"), api: "csp_Test")
        let first = Site(key: "one::test", name: "Source A", type: 3, api: "csp_Test", csp: definition)
        let second = Site(key: "two::test", name: "Source B", type: 3, api: "csp_Test", csp: definition)
        let movie = video(urls: ["opaque-id"])
        let line = try #require(movie.lines.first)
        let episode = try #require(line.episodes.first)
        #expect(await checker.filter([movie], site: first).count == 1)
        await checker.markCrawlerUnavailable(site: first, line: line, episode: episode)
        #expect(await checker.filter([movie], site: first).isEmpty)
        #expect(await checker.filter([movie], site: second).count == 1)
    }

    @Test func enrichesCatalogSummariesWithoutDiscardingUnknownDetails() async {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [VODSearchProtocol.self]
        let service = TVService(session: URLSession(configuration: configuration))
        let site = Site(key: "cms", name: "CMS", type: 1, api: fixture + "/batch")
        let checked = await service.checkedCatalogVideos([video("Bad"), video("Good"), video("Unknown")],
                                                        site: site, availability: availability())
        #expect(checked.map(\.title) == ["Good", "Unknown"])
        #expect(checked.first?.lines.isEmpty == true)
    }

    @Test func switchingMatchesEpisodeLabelsRatherThanArrayOffsets() throws {
        var candidate = video("Example　Show", urls: [fixture + "/ready", fixture + "/other"])
        candidate.lines[0].episodes[0].name = "EP02"
        candidate.lines[0].episodes[1].name = "EP01"
        #expect(VODMatch.titleKey(candidate) == VODMatch.titleKey(video()))
        #expect(!VODMatch.sameTitle(candidate, video(year: "2020")))
        let match = try #require(VODMatch.matchingEpisode(Episode(name: "第01集", url: "opaque"), in: candidate, singleEpisode: false))
        #expect(match.1 == 1)
        var otherSeason = video(urls: [fixture + "/ready"])
        otherSeason.lines[0].episodes[0].name = "S02E03"
        #expect(VODMatch.matchingEpisode(Episode(name: "S01E03", url: "opaque"), in: otherSeason, singleEpisode: true) == nil)
    }

    @Test func playbackSearchShowsOnlyTheTenBestDistinctSources() {
        let reference = video()
        let episode = Episode(name: "第02集", url: "opaque")
        func hit(_ key: String, id: String, year: String = "2024", episodeName: String? = nil) -> VODSearchHit {
            var item = video(year: year, urls: episodeName == nil ? [] : [fixture + "/ready"])
            item.id = id
            if let episodeName { item.lines[0].episodes[0].name = episodeName }
            return VODSearchHit(video: item, source: VODSearchSource(subscription: "Demo",
                site: Site(key: key, name: key, type: 1, api: fixture)))
        }
        let wrong = [hit("1", id: "wrong-year", year: "2020", episodeName: "EP02"),
                     hit("2", id: "wrong-episode", episodeName: "EP03")]
        let best = hit("z", id: "matching-episode", episodeName: "EP02")
        let duplicate = hit("z", id: "summary")
        let unknownYear = hit("a", id: "unknown-year", year: "", episodeName: "EP02")
        let summaries = (0..<12).map { hit("source-\($0)", id: "summary") }
        let results = VODMatch.topPlaybackSources(for: reference, episode: episode, singleEpisode: false,
                                                  from: wrong + [duplicate, unknownYear] + summaries + [best])
        #expect(results.count == 10)
        #expect(results.first == best)
        #expect(Set(results.map(\.source.id)).count == 10)
        #expect(results.allSatisfy { $0.video.id != "wrong-year" && $0.video.id != "wrong-episode" })
    }

    @MainActor @Test func aggregateSearchKeepsSuccessfulSitesWhenAnotherFails() async {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [VODSearchProtocol.self]
        let service = TVService(session: URLSession(configuration: configuration))
        let sources = ["first", "second", "failed", "disabled"].map { key in
            VODSearchSource(subscription: key, site: Site(key: key, name: key, type: 1,
                api: fixture + "/search-" + key, searchable: key != "disabled"))
        }
        var hits: [VODSearchHit] = [], failures = 0
        await service.searchAcrossSources(sources, query: "Example", availability: availability()) { _, results, success in
            hits += results
            if !success { failures += 1 }
        }
        #expect(Set(hits.map(\.source.id)) == ["first", "second"])
        #expect(Set(hits.map(\.id)).count == 2)
        #expect(failures == 1)
    }

    @MainActor @Test func playbackSearchIgnoresUnrelatedAndExpiredCatalogResults() async {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [VODSearchProtocol.self]
        let service = TVService(session: URLSession(configuration: configuration))
        let site = Site(key: "mixed", name: "Mixed", type: 1, api: fixture + "/search-mixed")
        let source = VODSearchSource(subscription: "Test", site: site)
        let target = VODPlaybackSearch(video: video(), episode: Episode(name: "第01集", url: "opaque"), singleEpisode: false)
        var ids: [String] = []
        await service.searchAcrossSources([source], query: "Example", availability: availability(), matching: target) { checked, hits, success in
            #expect(checked == source)
            #expect(success)
            ids += hits.map(\.video.id)
        }
        #expect(ids == ["ready"])
    }

    @MainActor @Test func playbackSearchContinuesOnlyWhenABatchHasNoUsableEpisode() async {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [VODSearchProtocol.self]
        let service = TVService(session: URLSession(configuration: configuration))
        let target = VODPlaybackSearch(video: video(), episode: Episode(name: "第01集", url: "opaque"), singleEpisode: false)
        for firstMatch in [1, 13] {
            let sources = (0..<30).map { index in
                VODSearchSource(subscription: "Test", site: Site(key: "source-\(index)", name: "Source \(index)", type: 1,
                    api: fixture + "/batch-playback/\(firstMatch)/\(index)"))
            }
            var checked = 0
            var matches: [VODSearchHit] = []
            await service.searchPlaybackSources(sources, for: target, availability: availability(),
                                                hasResults: { !matches.isEmpty }) { _, hits in
                checked += 1
                matches += hits
            }
            #expect(checked == (firstMatch < 10 ? 10 : 20))
            #expect(matches.map(\.source.id) == ["source-\(firstMatch)"])
            #expect(matches.first?.video.lines.first?.name == "Working")
        }
    }

    @Test func playbackCacheExpiresAndDiscardsChangedSourceConfigurations() throws {
        let reference = video()
        let episode = Episode(name: "第01集", url: "opaque")
        let target = VODPlaybackSearch(video: reference, episode: episode, singleEpisode: false)
        let key = VODPlaybackSearchCache.Key(siteID: "current", search: target)
        let anotherEpisode = VODPlaybackSearch(video: reference, episode: Episode(name: "第02集", url: "opaque"), singleEpisode: false)
        let site = Site(key: "other", name: "Other", type: 1, api: fixture + "/old")
        let source = VODSearchSource(subscription: "Test", site: site)
        let hit = VODSearchHit(video: reference, source: source)
        var progress = VODPlaybackSearchCache.Results()
        progress.checked[site.id] = site
        progress.pages = [[hit]]
        var cache = VODPlaybackSearchCache()
        let start = Date(timeIntervalSince1970: 1000)
        cache.save(progress, for: key, now: start)
        let cached = try #require(cache.results(for: key, now: start.addingTimeInterval(119)))
        #expect(cached.retaining([source]).pages == [[hit]])
        var changed = site
        changed.api = fixture + "/new"
        let pruned = cached.retaining([VODSearchSource(subscription: "Test", site: changed)])
        #expect(pruned.checked.isEmpty && pruned.pages.isEmpty)
        #expect(cache.results(for: VODPlaybackSearchCache.Key(siteID: "current", search: anotherEpisode), now: start) == nil)
        #expect(cache.results(for: key, now: start.addingTimeInterval(120)) == nil)
    }

    @Test func playbackSearchSkipsDuplicateEndpointsAndKeepsDistinctHeaders() {
        let current = Site(key: "current", name: "Current", type: 1, api: fixture, headers: ["User-Agent": "A"])
        let sites = [
            Site(key: "duplicate-current", name: "Duplicate", type: 1, api: fixture, headers: ["user-agent": "A"]),
            Site(key: "distinct", name: "Distinct", type: 1, api: fixture, headers: ["user-agent": "B"]),
            Site(key: "duplicate-distinct", name: "Duplicate", type: 1, api: fixture, headers: ["User-Agent": "B"])
        ]
        let alternatives = VODSearchSource.playbackAlternatives(
            in: sites.map { VODSearchSource(subscription: "Test", site: $0) }, excluding: current)
        #expect(alternatives.map(\.id) == ["distinct"])
    }
}

private final class VODSearchProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let url = request.url else { return }
        if url.path == "/timeout" {
            client?.urlProtocol(self, didFailWithError: URLError(.timedOut))
            return
        }
        var status = 200
        switch url.path {
        case "/gone": status = 410
        case "/missing": status = 404
        case "/denied": status = 403
        case "/temporary", "/search-failed": status = 503
        default: break
        }
        let queries = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems
        let json: String
        if url.path == "/batch", queries?.contains(URLQueryItem(name: "ids", value: "Bad,Good,Unknown")) == true {
            json = #"{"list":[{"vod_id":"Bad","vod_name":"Bad","vod_play_from":"HD","vod_play_url":"正片$https://media.example.invalid/gone"},{"vod_id":"Good","vod_name":"Good","vod_play_from":"HD","vod_play_url":"正片$https://media.example.invalid/ready"}]}"#
        } else if url.path == "/search-mixed" {
            json = #"{"list":[{"vod_id":"unrelated","vod_name":"Other Show"},{"vod_id":"remake","vod_name":"Example Show","vod_year":"2025"},{"vod_id":"expired","vod_name":"Example Show","vod_year":"2024","vod_play_from":"HD","vod_play_url":"EP1$https://media.example.invalid/gone"},{"vod_id":"ready","vod_name":"Example Show","vod_year":"2024","vod_play_from":"HD","vod_play_url":"EP1$https://media.example.invalid/ready"}]}"#
        } else if url.path.hasPrefix("/batch-playback/") {
            let components = url.path.split(separator: "/")
            let found = (components.last == components.dropLast().last)
            let isDetail = queries?.contains(where: { $0.name == "ids" }) == true
            if found && isDetail {
                json = #"{"list":[{"vod_id":"shared","vod_name":"Example Show","vod_year":"2024","vod_play_from":"Expired$$$Working","vod_play_url":"EP1$https://media.example.invalid/gone$$$第01集$https://media.example.invalid/ready"}]}"#
            } else if found {
                json = #"{"list":[{"vod_id":"shared","vod_name":"Example Show","vod_year":"2024"}]}"#
            } else {
                json = #"{"list":[{"vod_id":"wrong-episode","vod_name":"Example Show","vod_year":"2024","vod_play_from":"HD","vod_play_url":"EP2$https://media.example.invalid/ready"}]}"#
            }
        } else {
            json = #"{"list":[{"vod_id":"shared","vod_name":"Example Show","vod_year":"2024"}]}"#
        }
        let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(json.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
