import Foundation
import Testing
@testable import TVBoxCore

@Suite struct LiveAddressTests {
    @Test func explicitLabelsAreRemovedFromPathAndQuery() {
        #expect(Parser.liveAddress("https://example.org/a.m3u8$LR•6•IPV4『线路4』") == "https://example.org/a.m3u8")
        #expect(Parser.liveAddress("https://example.org/migu.php?id=cctv1$LR•6•IPV4『线路1』") == "https://example.org/migu.php?id=cctv1")
        #expect(Parser.liveAddress("https://example.org/a.m3u8$线路2") == "https://example.org/a.m3u8")
    }
    @Test func encodedLabelsAreRemovedWithoutDecodingCredentials() {
        let label = "LR•6•IPV4『线路5』".addingPercentEncoding(withAllowedCharacters: .urlPathAllowed)!
        #expect(Parser.liveAddress("https://example.org/a?auth=a%2Bb%2Fc$" + label) == "https://example.org/a?auth=a%2Bb%2Fc")
    }
    @Test func literalAndEscapedDollarsInsideQuerySurvive() {
        for url in ["https://example.org/a?token=a$b", "https://example.org/a?token=a%24b", "https://example.org/a$b/video.m3u8", "https://example.org/a?token=$LRtoken"] {
            #expect(Parser.liveAddress(url) == url)
        }
        #expect(Parser.liveAddress("https://example.org/a?token=a$b$LR•6•IPV4『线路2』") == "https://example.org/a?token=a$b")
    }
    @Test func playlistSeparatesNotesAndKeepsRequestHeaders() {
        let list = Parser.playlist("央视,#genre#\nCCTV1,https://example.org/live.m3u8?token=a$b$LR•6•IPV4『线路2』|User-Agent=MyPlayer&Authorization=Bearer%20secret")
        #expect(list.count == 1)
        #expect(list[0].urls == ["https://example.org/live.m3u8?token=a$b"])
        #expect(list[0].headers["Authorization"] == "Bearer secret")
        #expect(list[0].headers["User-Agent"] == "MyPlayer")
    }
    @Test func inlineAndPreviouslySavedChannelsUseCleanAddresses() throws {
        let config = try Parser.configuration(Data(#"{"lives":[{"name":"央视","channels":[{"name":"CCTV1","urls":["https://example.org/a.m3u8$线路1"]}]}]}"#.utf8))
        #expect(config.channels[0].urls == ["https://example.org/a.m3u8"])
        let old = Channel(name: "CCTV1", group: "央视", urls: ["https://example.org/a.m3u8$LR•6•IPV4『线路1』", "https://example.org/a.m3u8"])
        let index = ChannelIndex(channels: [old])
        #expect(index.channels[0].urls == ["https://example.org/a.m3u8"])
        #expect(index.routeCount == 1)
    }
}
