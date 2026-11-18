import Foundation
import Testing
@testable import TVBoxCore

private actor CSPFixture: CSPTransport {
    struct Call: Sendable { let key: String; let command: CSPCommand; let arguments: [String: String] }
    private var received: [Call] = []
    func calls() -> [Call] { received }
    func invoke(site: Site, command: CSPCommand, arguments: [String: String]) async throws -> Data {
        received.append(Call(key: site.key, command: command, arguments: arguments))
        let value: String
        switch command {
        case .home: value = #"{"class":[{"type_id":"films","type_name":"测试分类"}]}"#
        case .homeVideo, .category, .search: value = #"{"list":[{"vod_id":"film:42","vod_name":"公开测试片"}],"page":2,"pagecount":3}"#
        case .detail: value = #"{"list":[{"vod_id":"film:42","vod_name":"公开测试片","vod_play_from":"测试线路","vod_play_url":"第1集$opaque:episode$token"}]}"#
        case .player: value = #"{"url":"https://video.invalid/clip.mp4","parse":0,"header":{"User-Agent":"Spider fixture","referer":"https://site.invalid/"}}"#
        }
        return Data(value.utf8)
    }
}

@Suite struct CSPServiceTests {
    private func site() throws -> Site {
        Site(key: "subscription::site", name: "Fixture", type: 3, api: "csp_Demo", headers: ["user-agent": "Original", "X-Fixture": "preserved"], csp: try CSPDefinition(component: CSPComponent("https://source.invalid/component.jar"), api: "csp_Demo"))
    }
    @Test func catalogDetailAndPlaybackPassOriginalIDsAndHeaders() async throws {
        let source = try site(), fixture = CSPFixture(), service = TVService(csp: fixture)
        #expect(service.supports(source))
        let categories = try await service.categories(site: source)
        #expect(categories.map(\.id) == ["films"])
        let catalog = try await service.catalog(site: source, category: "films", page: 2)
        #expect(catalog.page == 2 && catalog.pageCount == 3)
        let detail = try await service.detail(video: catalog.videos[0], site: source)
        let line = detail.lines[0], episode = line.episodes[0]
        #expect(episode.url == "opaque:episode$token")
        let playback = try await service.resolvePlayback(site: source, line: line, episode: episode)
        #expect(playback.url.absoluteString == "https://video.invalid/clip.mp4")
        #expect(playback.headers["User-Agent"] == "Spider fixture")
        #expect(playback.headers["user-agent"] == nil)
        #expect(playback.headers["X-Fixture"] == "preserved")
        let calls = await fixture.calls()
        #expect(calls.map(\.command) == [.home, .category, .detail, .player])
        #expect(calls.allSatisfy { $0.key == "subscription::site" })
        #expect(calls[1].arguments["category"] == "films" && calls[1].arguments["page"] == "2")
        #expect(calls[2].arguments["id"] == "film:42")
        #expect(calls[3].arguments["id"] == "opaque:episode$token" && calls[3].arguments["flag"] == "测试线路")
    }
    @Test func recommendationAndSearchUseDifferentSpiderMethods() async throws {
        let source = try site(), fixture = CSPFixture(), service = TVService(csp: fixture)
        _ = try await service.catalog(site: source)
        _ = try await service.catalog(site: source, search: "公开测试片", page: 3)
        let calls = await fixture.calls()
        #expect(calls.map(\.command) == [.home, .homeVideo, .search])
        #expect(calls[2].arguments["query"] == "公开测试片" && calls[2].arguments["page"] == "3")
    }
    @Test(arguments: [false, true]) func noHomeRecommendationsStillLoadsTheFirstCategory(fails: Bool) async throws {
        let fixture = CategoriesOnlyFixture(fails: fails)
        let listing = try await TVService(csp: fixture).catalog(site: site(), page: 2)
        #expect(listing.videos.count == 1 && listing.categories.map(\.id) == ["films"])
        #expect(await fixture.commands == [.home, .homeVideo, .category])
        #expect(await fixture.categoryArguments == ["category": "films", "page": "2"])
    }
    @Test func missingRuntimeDoesNotBecomeACompatibleCMS() async throws {
        let source = try site(), service = TVService()
        #expect(!service.supports(source) && !source.supported)
        await #expect(throws: (any Error).self) { try await service.categories(site: source) }
        #expect(throws: (any Error).self) { try service.requestURL(site: source, parameters: [:]) }
    }
    @Test func refusesUnresolvedPagesAndInvalidHeadersOrSchemes() throws {
        for value in [#"{"url":"https://site.invalid/watch/1","parse":1}"#,
                      #"{"url":"https://site.invalid/watch/1","parse":0,"jx":1}"#,
                      #"{"url":"file:///etc/passwd","parse":0}"#,
                      #"{"url":"http://127.0.0.1:9978/proxy?do=video","parse":0}"#,
                      #"{"url":"http://localhost:9978/proxy","parse":0}"#,
                      #"{"url":"http://[::1]:9978/proxy","parse":0}"#,
                      #"{"url":"http://192.168.127.2:9978/proxy","parse":0}"#,
                      #"{"url":"https://video.invalid/a.mp4","header":{"Cookie":"a\r\nb"}}"#] {
            #expect(throws: (any Error).self) { try CSPPlayback(data: Data(value.utf8)) }
        }
    }
    @Test(arguments: [
        (#"{"url":"","msg":"请先登录后播放。","code":403}"#, "要求登录"),
        (#"{"error":{"status":403}}"#, "拒绝访问"),
        (#"{"code":"404"}"#, "找不到该视频"),
        (#"{"url":"链接已过期"}"#, "链接已失效"),
        (#"{"statusCode":504}"#, "请求超时"),
        (#"{"error":"RATE_LIMITED"}"#, "限制了请求频率"),
        (#"{"status":503}"#, "服务暂不可用"),
        (#"{"url":null,"msg":"未知错误 token=private"}"#, "未返回本线路的播放地址"),
        (#"{"url":"   ","message":"不需要登录"}"#, "未返回本线路的播放地址"),
        (#"{"url":[]}"#, "播放地址格式不正确"),
        (#"{"url":"401"}"#, "播放地址格式不正确"),
        (#"{"url":"file:///somewhere"}"#, "不支持的协议"),
        (#"{"parse":1}"#, "需要网页解析"),
        ("not json", "播放结果格式无效"),
    ]) func explainsPlaybackFailureUsingSourceResponse(value: String, expected: String) {
        do {
            _ = try CSPPlayback(data: Data(value.utf8))
            Issue.record("Expected the source response to fail")
        } catch {
            #expect(error.localizedDescription.contains(expected))
            #expect(!error.localizedDescription.contains("token=private"))
        }
    }
    @Test func keepsValidPlaybackWithInformationalMetadata() throws {
        let value = #"{"url":"https://video.invalid/clip.mp4","msg":"需要会员","code":1}"#
        #expect(try CSPPlayback(data: Data(value.utf8)).url.absoluteString == "https://video.invalid/clip.mp4")
    }
    @Test func sourceCanReturnAQRCodeInsteadOfPlayback() throws {
        let payload = "https://auth.example.invalid/scan?fixture=1"
        let responses = [
            (#"{"url":"","qrcode":"https://auth.example.invalid/scan?fixture=1"}"#, CSPPlaybackAuthorization.code(payload)),
            (#"{"parse":1,"url":"https://auth.example.invalid/sign-in","auth":{"qrCode":"https://auth.example.invalid/scan?fixture=1"}}"#, .code(payload)),
            (#"{"auth":{"qr_image":"data:image/png;base64,iVBORw0KGgo="}}"#, .image(Data([137, 80, 78, 71, 13, 10, 26, 10]))),
        ]
        for (response, expected) in responses {
            do {
                _ = try CSPPlayback(data: Data(response.utf8))
                Issue.record("Expected a QR authorization challenge")
            } catch {
                #expect((error as? CSPPlaybackAuthorization) == expected)
                #expect(!error.localizedDescription.contains(payload))
            }
        }
    }
    @Test func ignoresInvalidOrIrrelevantQRCodeFields() throws {
        let valid = #"{"url":"https://video.invalid/clip.mp4","qrcode":"stale"}"#
        #expect(try CSPPlayback(data: Data(valid.utf8)).url.host == "video.invalid")
        for qr in ["", "DATA:image/svg+xml;base64,AA==", String(repeating: "x", count: 1025)] {
            let bytes = try JSONSerialization.data(withJSONObject: ["code": 401, "qrcode": qr])
            do {
                _ = try CSPPlayback(data: bytes)
                Issue.record("Expected a login error without a QR code")
            } catch {
                #expect(!(error is CSPPlaybackAuthorization))
                #expect(error.localizedDescription.contains("要求登录"))
            }
        }
    }
    @Test func rpcConnectionAcceptsOnlyPrivateLoopbackAndStrongSessionTokens() throws {
        let token = String(repeating: "a", count: 64)
        _ = try CSPWorkerConnection(endpoint: URL(string: "http://127.0.0.1:18793")!, token: token)
        for value in ["https://source.invalid:18793", "http://127.0.0.1.evil.invalid:18793", "http://user@127.0.0.1:18793", "http://127.0.0.1:18793?token=x", "http://127.0.0.1:18793#token", "http://127.0.0.1:18793/unexpected"] {
            #expect(throws: (any Error).self) { try CSPWorkerConnection(endpoint: URL(string: value)!, token: token) }
        }
        #expect(throws: (any Error).self) { try CSPWorkerConnection(endpoint: URL(string: "http://127.0.0.1:18793")!, token: "short") }
    }
}

private actor CategoriesOnlyFixture: CSPTransport {
    let fails: Bool
    var commands: [CSPCommand] = []
    var categoryArguments: [String: String] = [:]
    init(fails: Bool) { self.fails = fails }
    func invoke(site: Site, command: CSPCommand, arguments: [String:String]) async throws -> Data {
        commands.append(command)
        switch command {
        case .home: return Data(#"{"class":[{"type_id":"films","type_name":"电影"}],"list":[]}"#.utf8)
        case .homeVideo:
            if fails { throw TVError.message("No recommendation method") }
            return Data(#"{"list":[]}"#.utf8)
        case .category:
            categoryArguments = arguments
            return Data(#"{"list":[{"vod_id":"fixture:1","vod_name":"分类影片"}],"page":2,"pagecount":3}"#.utf8)
        default: throw TVError.message("Unexpected command")
        }
    }
}
