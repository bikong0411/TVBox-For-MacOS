import Foundation
import Testing
@testable import TVBoxCore

@Suite struct ProgrammeGuideTests {
    private let base = URL(string: "https://fixture.invalid/live/main.m3u")!
    private let zone = TimeZone(secondsFromGMT: 8 * 3600)!
    private func time(_ value: String) -> Date { ISO8601DateFormatter().date(from: value)! }
    private var day: Date { time("2026-11-09T04:00:00Z") }
    private var calendar: Calendar { var c = Calendar(identifier: .gregorian); c.timeZone = zone; return c }
    @Test func playlistMetadataSurvivesImportAndLibraryStorage() throws {
        let config = try Parser.configuration(Data("""
        #EXTM3U x-tvg-url="../guide.xml" catchup-days="3"
        #EXTINF:-1 tvg-id="c1" tvg-name="央视一套" catchup="default" catchup-source="../archive/{utc}-{duration}.m3u8",CCTV1
        https://fixture.invalid/live/1.m3u8
        #EXTINF:-1,CCTV2
        https://fixture.invalid/live/2.m3u8
        """.utf8), base: base)
        let info = try #require(config.channels.first?.guide)
        #expect(info.url == "https://fixture.invalid/guide.xml")
        #expect(info.channelID == "c1" && info.channelName == "央视一套")
        #expect(info.catchup?.source == "https://fixture.invalid/archive/{utc}-{duration}.m3u8")
        #expect(info.catchup?.days == 3)
        #expect(config.channels[1].guide?.catchup == nil)
        var library = SourceLibrary(); try library.add(config, target: .live)
        let restored = try JSONDecoder().decode(SourceLibrary.self, from: JSONEncoder().encode(library))
        #expect(restored.activeLive?.configuration.channels.first?.guide == info)
    }
    @Test func oldSavedSourcesDecodeWithoutMetadataOrChangedIDs() throws {
        let data = Data(#"{"name":"旧频道","group":"央视","logo":"","urls":["https://fixture.invalid/live"],"headers":{}}"#.utf8)
        let channel = try JSONDecoder().decode(Channel.self, from: data)
        #expect(channel.guide == nil)
        #expect(channel.id == Channel(name: "旧频道", group: "央视", urls: ["https://fixture.invalid/live"]).id)
        let feed = try JSONDecoder().decode(LiveFeed.self, from: Data(#"{"name":"旧订阅","url":"https://fixture.invalid/live.m3u","headers":{}}"#.utf8))
        #expect(feed.guide == nil)
    }
    @Test func tvboxEpgIsInheritedByTXTAndTemplatesStayIntact() throws {
        let config = try Parser.configuration(Data(#"{"epg":"../epg?ch={name}&date={date}","lives":[{"name":"央视","url":"./live.txt"}]}"#.utf8), base: base)
        let feed = try #require(config.feeds.first)
        let channels = Parser.playlist("CCTV1,https://fixture.invalid/1", guide: feed.guide)
        #expect(channels.first?.guide?.url == "https://fixture.invalid/epg?ch={name}&date={date}")
        #expect(channels.first?.guide?.channelID == "")
    }
    @Test func mergedRoutesDoNotBorrowAnotherProvidersCatchupTemplate() {
        let a = Channel(name: "CCTV1", urls: ["https://a.invalid/live"])
        let b = Channel(name: "CCTV1", urls: ["https://b.invalid/live"], guide: LiveGuideInfo(url: "https://b.invalid/epg", catchup: CatchupTemplate(mode: "append", source: "?utc={utc}")))
        let index = ChannelIndex(channels: [a, b]); #expect(index.channels.count == 1)
        #expect(index.channels[0].guide == nil)
    }
    @Test func xmltvUsesIDsTimezonesAndInfersMissingStop() throws {
        let xml = """
        <tv><channel id="c1"><display-name>央视一套</display-name></channel>
        <programme channel="c1" start="20261109190000 +0800" stop="20261109193000 +0800" catchup-id="episode1"><title><![CDATA[新闻 & 资讯]]></title><desc>节目简介</desc></programme>
        <programme channel="c1" start="20261109200000 +0800"><title>电视剧</title></programme>
        <programme channel="c1" start="20261109210000 +0800" stop="20261109220000 +0800"><title>纪录片</title></programme>
        <programme channel="other" start="20261109190000 +0800"><title>其他频道</title></programme></tv>
        """
        let guide = try ProgrammeGuide.parse(Data(xml.utf8), day: day)
        let channel = Channel(name: "CCTV1", urls: ["https://fixture.invalid"], guide: LiveGuideInfo(channelID: "c1"))
        let items = guide.programmes(for: channel, day: day, calendar: calendar)
        #expect(items.count == 3)
        #expect(items[0].start == time("2026-11-09T11:00:00Z"))
        #expect(items[0].title == "新闻 & 资讯" && items[0].catchupID == "episode1")
        #expect(items[1].end == items[2].start)
        #expect(items[0].isOnAir(at: time("2026-11-09T11:15:00Z")))
        var byName = channel; byName.guide = LiveGuideInfo(channelName: "央视一套")
        #expect(guide.programmes(for: byName, day: day, calendar: calendar) == items)
        byName.guide?.channelID = "missing"
        #expect(guide.programmes(for: byName, day: day, calendar: calendar).isEmpty)
    }
    @Test func xmltvDefaultsToUTCAndRejectsAmbiguousNames() throws {
        let guide = try ProgrammeGuide.parse(Data("""
        <tv><channel id="a"><display-name>新闻</display-name></channel><channel id="b"><display-name>新闻</display-name></channel>
        <programme channel="a" start="202611091900" stop="202611092000"><title>节目</title></programme></tv>
        """.utf8), day: day)
        #expect(guide.programmes["a"]?.first?.start == time("2026-11-09T19:00:00Z"))
        #expect(guide.programmes(for: Channel(name: "新闻", urls: []), day: day, calendar: calendar).isEmpty)
        #expect(throws: (any Error).self) { try ProgrammeGuide.parse(Data("<html>网页</html>".utf8), day: day) }
    }
    @Test func jsonGuideHandlesMidnightAndKeepsFutureProgrammes() throws {
        let guide = try ProgrammeGuide.parse(Data(#"{"channel_name":"CCTV1","date":"2026-11-09","epg_data":[{"title":"午夜节目","start":"23:30","end":"24:00"},{"title":"新闻","start":"19:00","end":"19:30"}]}"#.utf8), day: day, timeZone: zone)
        let items = guide.programmes["CCTV1"]!
        #expect(items.map(\.title) == ["新闻", "午夜节目"])
        #expect(items[1].end == time("2026-11-09T16:00:00Z"))
        #expect(items[0].start == time("2026-11-09T11:00:00Z"))
    }
    @Test func catchupRequiresPastProgrammeWithinProviderWindow() throws {
        let now = time("2026-11-09T12:00:00Z")
        let programme = Programme(channelID: "c1", title: "新闻", start: now.addingTimeInterval(-3600), end: now.addingTimeInterval(-1800))
        let template = CatchupTemplate(source: "https://fixture.invalid/{utc}-{duration}.m3u8", days: 2)
        let result = try #require(template.playbackURL(programme: programme, liveURL: "", now: now))
        #expect(result.path == "/\(Int(programme.start.timeIntervalSince1970))-1800.m3u8")
        var future = programme; future.start = now.addingTimeInterval(10); future.end = now.addingTimeInterval(20)
        #expect(template.playbackURL(programme: future, liveURL: "", now: now) == nil)
        #expect(template.playbackURL(programme: programme, liveURL: "", now: now.addingTimeInterval(3 * 86400)) == nil)
        var unknown = template; unknown.mode = "xc"; #expect(unknown.playbackURL(programme: programme, liveURL: "", now: now) == nil)
        unknown = template; unknown.correction = .infinity; #expect(unknown.playbackURL(programme: programme, liveURL: "", now: now) == nil)
        unknown.correction = 1e308; #expect(unknown.playbackURL(programme: programme, liveURL: "", now: now) == nil)
        unknown = template; unknown.source = "https://fixture.invalid/{unsupported}"; #expect(unknown.playbackURL(programme: programme, liveURL: "", now: now) == nil)
    }
    @Test func appendCatchupKeepsSignedLiveURLAndSupportsAliases() throws {
        let now = time("2026-11-09T12:00:00Z")
        let item = Programme(channelID: "c1", title: "新闻", start: now.addingTimeInterval(-3600), end: now.addingTimeInterval(-1800))
        let template = CatchupTemplate(mode: "append", source: "&start=${start}&end=${end}&duration=${duration}&at={Y}{m}{d}{H}{M}{S}")
        let url = try #require(template.playbackURL(programme: item, liveURL: "https://fixture.invalid/live?token=a$b", now: now, timeZone: zone))
        #expect(url.query?.hasPrefix("token=a$b&start=\(Int(item.start.timeIntervalSince1970))&end=") == true)
        #expect(url.query?.hasSuffix("&duration=1800&at=20261109190000") == true)
    }
    @Test func guideCacheSeparatesAuthorizationAndReusesMatchingResponse() async throws {
        let configuration = URLSessionConfiguration.ephemeral; configuration.protocolClasses = [GuideProtocol.self]
        let service = ProgrammeGuideService(service: TVService(session: URLSession(configuration: configuration)))
        let host = UUID().uuidString.lowercased() + ".invalid"
        var channel = Channel(name: "CCTV1", urls: [], headers: ["Authorization": "A"], guide: LiveGuideInfo(url: "https://\(host)/epg"))
        let a = try await service.programmes(channel: channel, day: day)
        channel.headers["Authorization"] = "B"
        let b = try await service.programmes(channel: channel, day: day)
        channel.headers["Authorization"] = "A"
        let again = try await service.programmes(channel: channel, day: day)
        #expect(a.first?.title == "节目A" && b.first?.title == "节目B" && again == a)
        #expect(GuideProtocol.count(host: host) == 2)
    }
}

private final class GuideProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    private static var counts: [String: Int] = [:]
    static func count(host: String) -> Int { lock.lock(); defer { lock.unlock() }; return counts[host] ?? 0 }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let url = request.url!
        Self.lock.lock(); Self.counts[url.host!, default: 0] += 1; Self.lock.unlock()
        let json: [String: Any] = ["channel_name": "CCTV1", "date": "2026-11-09", "epg_data": [["title": "节目" + (request.value(forHTTPHeaderField: "Authorization") ?? ""), "start": "12:00", "end": "13:00"]]]
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: try! JSONSerialization.data(withJSONObject: json)); client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
