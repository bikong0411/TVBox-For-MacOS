import Foundation
import Testing
@testable import TVBoxCore

@Suite struct WebVideoResolverTests {
    private let page = URL(string: "https://watch.example.org/series/episode")!

    @Test func readsVideoSourcesAndResolvesRelativeURLs() throws {
        let html = """
            <video controls><source type="application/x-mpegURL" src="media/manifest?mode=1&amp;quality=high">
            <source src="fallback.mp4"></video>
            <script>const ad = "https://ads.example.net/ad.mp4";</script>
            """
        let media = try WebVideoResolver.extract(from: html, page: page)
        #expect(media.absoluteString == "https://watch.example.org/series/media/manifest?mode=1&quality=high")
    }

    @Test func readsEscapedScriptLiteralsWithoutAssumingASitePath() throws {
        let html = #"<script>import "/player.ts"; const config = {"file":"https:\/\/cdn.example.net\/random\/clip.m3u8?token=a\u0026quality=hd"};</script>"#
        let media = try WebVideoResolver.extract(from: html, page: page)
        #expect(media.absoluteString == "https://cdn.example.net/random/clip.m3u8?token=a&quality=hd")
    }

    @Test func readsTheDocumentBaseForRelativeMedia() throws {
        let html = #"<base href="/assets/"><video src="trailer.mp4"></video>"#
        #expect(try WebVideoResolver.extract(from: html, page: page).absoluteString == "https://watch.example.org/assets/trailer.mp4")
    }

    @Test func ignoresMisleadingLinksAndRefusesAmbiguousCandidates() throws {
        let unusable = #"""
            <!-- <video src="https://ads.example.net/ad.mp4"></video> -->
            <a href="/download.mp4">Other content</a>
            <video src="file:///tmp/sample.mp4"></video>
            <video src="http://127.0.0.1/live.m3u8"></video>
            <video src="https://router.local/live.m3u8"></video>
            <meta property="og:video" content="https://watch.example.org/embed/42">
            """#
        #expect(throws: WebVideoResolver.Failure.noMedia) { try WebVideoResolver.extract(from: unusable, page: page) }
        let ambiguous = #"<script>const first="/a.m3u8", second="/b.m3u8";</script>"#
        #expect(throws: WebVideoResolver.Failure.multipleMedia) { try WebVideoResolver.extract(from: ambiguous, page: page) }
    }

    @Test func resolvesPublicPagesWithoutForwardingCredentialsToTheMediaHost() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [WebVideoProtocol.self]
        let resolver = WebVideoResolver(configuration: configuration)
        let headers = ["Cookie": "private=1", "Authorization": "Bearer private", "User-Agent": "TVBox Fixture"]
        let result = try await resolver.resolve(page, headers: headers)
        #expect(result == .media(URL(string: "https://cdn.example.net/stream.m3u8")!,
                                 headers: ["User-Agent": "TVBox Fixture", "Referer": "https://watch.example.org/"]))
        #expect(try await resolver.resolve(page.appendingPathComponent("live.m3u8")) == .direct)
        #expect(try await resolver.resolve(URL(string: "https://watch.example.org/hls")!) == .direct)
        #expect(try await resolver.resolve(URL(string: "https://watch.example.org/login-required")!) == .direct)
    }

    @Test func mpvUnknownFormatExplainsTheDistinctionBetweenPagesAndMedia() {
        let failure = PlaybackFailure(error: NSError(domain: "mpv", code: -17))
        #expect(failure.message.contains("视频直链"))
        #expect(failure.diagnostic == "mpv (-17)")
    }
}

private final class WebVideoProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let url = request.url!
        let status = url.path == "/login-required" ? 403 : 200
        let isHLS = url.path == "/hls"
        let type = isHLS ? "text/plain" : "text/html"
        let text = isHLS ? "#EXTM3U\n#EXTINF:5,\nsegment.ts" : #"<video src="https://cdn.example.net/stream.m3u8"></video>"#
        if request.value(forHTTPHeaderField: "Authorization") != nil || request.value(forHTTPHeaderField: "Cookie") != nil {
            client?.urlProtocol(self, didFailWithError: URLError(.userAuthenticationRequired))
            return
        }
        let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: ["Content-Type": type])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(text.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
