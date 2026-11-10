import Foundation
import Testing
@testable import TVBoxCore

@Suite struct TVBoxCoreTests {
    private let base = URL(string: "https://example.org/config/main.json")!
    @Test func testConfigurationRelativeURLsAndCompatibility() throws {
        let data = Data(#"{"name":"测试","sites":[{"key":"cms","name":"JSON","type":1,"api":"../api.php?token=abc","searchable":0},{"key":"jar","name":"爬虫","type":3,"api":"csp_Test"}],"lives":[{"name":"直播","url":"./live.m3u","ua":"TestPlayer"}]}"#.utf8)
        let config = try Parser.configuration(data, base: base)
        XCTAssertEqual(config.sites[0].api, "https://example.org/api.php?token=abc")
        XCTAssertTrue(config.sites[0].supported); XCTAssertFalse(config.sites[0].searchable)
        XCTAssertFalse(config.sites[1].supported); XCTAssertEqual(config.sites[1].api, "csp_Test")
        XCTAssertEqual(config.feeds[0].headers["User-Agent"], "TestPlayer")
        XCTAssertEqual(config.feeds[0].url, "https://example.org/config/live.m3u")
    }
    @Test func testJSON5AndNestedSubscription() throws {
        let config = try Parser.configuration(Data("{ urls: [{name: '主线路', url: './a.json'},], }".utf8), base: base)
        XCTAssertEqual(config.subscriptions.first?.url, "https://example.org/config/a.json")
    }
    @Test func testEmptyAndEncryptedConfigurationRejected() {
        XCTAssertThrowsError(try Parser.configuration(Data("{}".utf8)))
        XCTAssertThrowsError(try Parser.configuration(Data("2423abfdencrypted".utf8)))
    }
    @Test func testM3UAttributesHeadersRelativeURLsAndDeduplication() {
        let text = """
        #EXTM3U
        #EXTINF:-1 tvg-logo="./logo.png" group-title="纪录片",测试频道
        #EXTVLCOPT:http-user-agent=MyPlayer
        #EXTVLCOPT:http-referrer=https://example.org
        ./video.m3u8|Authorization=Bearer%20token
        #EXTINF:-1 group-title="纪录片",测试频道
        ./video.m3u8
        #EXTINF:-1 group-title="纪录片",测试频道
        ./video.m3u8
        #EXTINF:-1 group-title="其他",第二频道
        https://example.net/live
        """
        let list = Parser.playlist(text, base: base)
        // Different authentication headers are separate routes; exact repeats are removed.
        XCTAssertEqual(list.count, 3)
        XCTAssertEqual(list[0].group, "纪录片")
        XCTAssertEqual(list[0].logo, "https://example.org/config/logo.png")
        XCTAssertEqual(list[0].headers["User-Agent"], "MyPlayer")
        XCTAssertEqual(list[0].headers["Authorization"], "Bearer token")
        XCTAssertNil(list[1].headers["User-Agent"])
        XCTAssertEqual(list[1].name, "测试频道")
        XCTAssertEqual(list[2].name, "第二频道")
    }
    @Test func testTXTGroupsAndInlineChannels() throws {
        let list = Parser.playlist("央视,#genre#\nCCTV 1,https://example.org/a.m3u8\n卫视,#genre#\n测试,https://example.org/b.m3u8")
        XCTAssertEqual(list.map(\.group), ["央视", "卫视"])
        let config = try Parser.configuration(Data(#"{"lives":[{"name":"家庭","channels":[{"name":"频道","urls":["./1.m3u8","./2.m3u8"]}]}]}"#.utf8), base: base)
        XCTAssertEqual(config.channels[0].urls.count, 2)
    }
    @Test func testPlaybackLinesAndDollarInQuery() {
        let lines = Parser.lines(names: "线路A$$$线路B", urls: "第一集$https://e.org/1?token=a$b#第二集$https://e.org/2$$$正片$https://e.org/3")
        XCTAssertEqual(lines.count, 2); XCTAssertEqual(lines[0].episodes.count, 2)
        XCTAssertEqual(lines[0].episodes[0].url, "https://e.org/1?token=a$b")
        XCTAssertEqual(lines[1].episodes[0].name, "正片")
    }
    @Test func testJSONCMSNumericIDsAndHTMLSummary() throws {
        let data = Data(#"{"page":"2","pagecount":4,"class":[{"type_id":1,"type_name":"电影"}],"list":[{"vod_id":42,"vod_name":"影片","vod_pic":"./p.jpg","vod_content":"<p>一段 &amp; 故事</p>","vod_play_from":"mp4","vod_play_url":"正片$https://example.org/a.mp4"}]}"#.utf8)
        let result = try Parser.catalog(data, base: base)
        XCTAssertEqual(result.page, 2); XCTAssertEqual(result.pageCount, 4)
        XCTAssertEqual(result.categories[0].id, "1"); XCTAssertEqual(result.videos[0].id, "42")
        XCTAssertEqual(result.videos[0].summary, "一段 & 故事")
        XCTAssertEqual(result.videos[0].lines[0].episodes.count, 1)
    }
    @Test func testXMLCMSCDATAAndMultipleLines() throws {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?><rss><class><ty id="1">电影</ty></class><list page="1" pagecount="3"><video><id>9</id><name><![CDATA[影片 & 名称]]></name><pic>./p.jpg</pic><year>2024</year><dl><dd flag="hls"><![CDATA[第一集$https://e.org/1.m3u8#第二集$https://e.org/2.m3u8]]></dd><dd flag="mp4">正片$https://e.org/a.mp4</dd></dl><des><![CDATA[<p>简介</p>]]></des></video></list></rss>
        """
        let result = try Parser.catalog(Data(xml.utf8), base: base)
        XCTAssertEqual(result.categories.first?.name, "电影"); XCTAssertEqual(result.pageCount, 3)
        XCTAssertEqual(result.videos[0].title, "影片 & 名称")
        XCTAssertEqual(result.videos[0].lines.count, 2)
        XCTAssertEqual(result.videos[0].lines[0].episodes.count, 2)
        XCTAssertEqual(result.videos[0].summary, "简介")
    }
    @Test func testAPIURLPreservesAuthenticationAndReplacesParameters() throws {
        let site = Site(key: "s", name: "s", type: 1, api: "https://e.org/api?token=secret&ac=old&pg=3")
        let url = try TVService().requestURL(site: site, parameters: ["ac": "detail", "pg": "1", "wd": "中文 & 空格"])
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems!
        XCTAssertEqual(query.filter { $0.name == "ac" }.count, 1)
        XCTAssertEqual(query.first { $0.name == "token" }?.value, "secret")
        XCTAssertEqual(query.first { $0.name == "wd" }?.value, "中文 & 空格")
        XCTAssertThrowsError(try TVService().requestURL(site: Site(key: "x", name: "x", type: 3, api: "csp_X"), parameters: [:]))
    }
    @Test func testMalformedCatalogRejected() {
        XCTAssertThrowsError(try Parser.catalog(Data(#"{"code":403,"msg":"无权限"}"#.utf8)))
        XCTAssertThrowsError(try Parser.catalog(Data("<rss><video>".utf8)))
    }
    @Test func testLibraryRoundTripIncludesSourceAndProgress() throws {
        let entry = LibraryEntry(video: Demo.videos[0], site: Site(key: "s", name: "源", type: 1, api: "https://example.org/api"), episode: Demo.videos[0].lines[0].episodes[0], position: 125)
        let decoded = try JSONDecoder().decode(LibraryEntry.self, from: JSONEncoder().encode(entry))
        XCTAssertEqual(decoded.id, entry.id); XCTAssertEqual(decoded.position, 125); XCTAssertEqual(decoded.site?.name, "源")
    }
    @Test func testHTTPErrorAndHeaderForwarding() async throws {
        let configuration = URLSessionConfiguration.ephemeral; configuration.protocolClasses = [StubProtocol.self]
        let service = TVService(session: URLSession(configuration: configuration))
        do { _ = try await service.data(at: URL(string: "https://fixture.invalid/forbidden")!); XCTFail("Expected HTTP failure") }
        catch { XCTAssertTrue(error.localizedDescription.contains("403")) }
        let data = try await service.data(at: URL(string: "https://fixture.invalid/headers")!, headers: ["User-Agent": "Custom", "Authorization": "Bearer 123"])
        let result = try JSONSerialization.jsonObject(with: data) as! [String: String]
        XCTAssertEqual(result["ua"], "Custom"); XCTAssertEqual(result["auth"], "Bearer 123")
    }
    @Test func testServiceCatalogSearchAndDetail() async throws {
        let configuration = URLSessionConfiguration.ephemeral; configuration.protocolClasses = [StubProtocol.self]
        let service = TVService(session: URLSession(configuration: configuration))
        let site = Site(key: "fixture", name: "fixture", type: 1, api: "https://fixture.invalid/api?token=abc")
        let categories = try await service.categories(site: site)
        XCTAssertEqual(categories.first?.name, "电影")
        let catalog = try await service.catalog(site: site, category: "7", search: "测试", page: 2)
        XCTAssertEqual(catalog.videos.first?.title, "测试 / 7 / 2")
        let detail = try await service.detail(video: catalog.videos[0], site: site)
        XCTAssertEqual(detail.lines.first?.episodes.first?.name, "正片")
    }
}

// Keep comparisons readable while reporting their original call locations.
private func XCTAssertEqual<T: Equatable>(_ actual: T, _ expected: T, sourceLocation: SourceLocation = #_sourceLocation) {
    #expect(actual == expected, sourceLocation: sourceLocation)
}
private func XCTAssertTrue(_ value: Bool, sourceLocation: SourceLocation = #_sourceLocation) { #expect(value, sourceLocation: sourceLocation) }
private func XCTAssertFalse(_ value: Bool, sourceLocation: SourceLocation = #_sourceLocation) { #expect(!value, sourceLocation: sourceLocation) }
private func XCTAssertNil<T>(_ value: T?, sourceLocation: SourceLocation = #_sourceLocation) { #expect(value == nil, sourceLocation: sourceLocation) }
private func XCTAssertThrowsError<T>(_ value: @autoclosure () throws -> T, sourceLocation: SourceLocation = #_sourceLocation) {
    do { _ = try value(); Issue.record("Expected an error", sourceLocation: sourceLocation) } catch {}
}
private func XCTFail(_ message: String, sourceLocation: SourceLocation = #_sourceLocation) { Issue.record(Comment(rawValue: message), sourceLocation: sourceLocation) }

final class StubProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let url = request.url!; var status = 200; var json: Any = [:]
        if url.path == "/forbidden" { status = 403 }
        else if url.path == "/headers" { json = ["ua": request.value(forHTTPHeaderField: "User-Agent") ?? "", "auth": request.value(forHTTPHeaderField: "Authorization") ?? ""] }
        else {
            let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
            func value(_ name: String) -> String { items.first { $0.name == name }?.value ?? "" }
            if value("ac") == "list" { json = ["class": [["type_id": "7", "type_name": "电影"]]] }
            else { json = ["page": 2, "pagecount": 3, "list": [["vod_id": "42", "vod_name": "\(value("wd")) / \(value("t")) / \(value("pg"))", "vod_play_from": "mp4", "vod_play_url": value("ids").isEmpty ? "" : "正片$https://e.org/test.mp4"]]] }
        }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: (try? JSONSerialization.data(withJSONObject: json)) ?? Data())
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
