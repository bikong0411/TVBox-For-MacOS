import Foundation
import Testing
@testable import TVBoxCore

@Suite struct ConfigurationPayloadTests {
    private let json5 = """
    {
      // Wrapped transport may contain JSON5 comments and trailing commas.
      name: '封装测试',
      sites: [{key: 'cms', name: '测试接口', type: 1, api: './api',},],
      lives: [{name: '直播', url: './live.m3u',}],
    }
    """
    @Test func JPEGEnvelopeWithBinaryPrefixAndJSON5() throws {
        var bytes = Data([0xFF, 0xD8, 0xFF, 0xE0, 0, 2, 0xA7, 0xFF, 0xD9])
        bytes.append(Data(("random**" + Data(json5.utf8).base64EncodedString()).utf8))
        let config = try Parser.configuration(bytes, base: URL(string: "http://example.org/tv"))
        #expect(config.name == "封装测试")
        #expect(config.sites.first?.api == "http://example.org/api")
        #expect(config.feeds.first?.url == "http://example.org/live.m3u")
    }
    @Test func PNGAndBMPEnvelopes() throws {
        for header in [[UInt8](arrayLiteral: 0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A), [0x42, 0x4D]] {
            var bytes = Data(header); bytes.append(Data(("**" + Data(json5.utf8).base64EncodedString()).utf8))
            #expect(try Parser.configuration(bytes).sites.count == 1)
        }
    }
    @Test func BOMAndBase64WithoutPadding() throws {
        var bomJSON = Data([0xEF, 0xBB, 0xBF]); bomJSON.append(Data(json5.utf8))
        #expect(try Parser.configuration(bomJSON).sites.count == 1)
        let encoded = bomJSON.base64EncodedString().replacingOccurrences(of: "=", with: "")
        #expect(try Parser.configuration(Data(encoded.utf8)).name == "封装测试")
    }
    @Test func MarkerInsideNormalJSONRemainsUntouched() throws {
        let data = Data(#"{"sites":[{"key":"x","name":"a**b","type":1,"api":"https://e.org/api"}]}"#.utf8)
        #expect(try Parser.configuration(data).sites[0].name == "a**b")
    }
    @Test func InvalidImagePayloadHasReadableError() {
        do {
            _ = try Parser.configuration(Data([0xFF, 0xD8, 0xFF, 0xD9]))
            Issue.record("Expected image response rejection")
        } catch { #expect(error.localizedDescription.contains("图片")) }
    }
    @Test func HTMLWithLinksIsNotMisidentifiedAsAPlaylist() {
        let html = Data("<!doctype html><html><script>let a=1,b='https://example.org';</script></html>".utf8)
        do { _ = try Parser.configuration(html); Issue.record("Expected HTML rejection") }
        catch { #expect(error.localizedDescription.contains("网页")) }
    }
    @Test func VideoPlaylistIsDistinguishedFromChannelList() {
        let hls = Data("#EXTM3U\n#EXT-X-VERSION:3\n#EXTINF:6,\nsegment.ts\n".utf8)
        do { _ = try Parser.configuration(hls); Issue.record("Expected HLS media rejection") }
        catch { #expect(error.localizedDescription.contains("打开视频")) }
    }
    @Test func WrappedSpiderRemainsMarkedUnsupported() throws {
        let json = #"{"sites":[{"key":"jar","name":"爬虫","type":3,"api":"csp_Demo"}]}"#
        let bytes = Data(("payload**" + Data(json.utf8).base64EncodedString()).utf8)
        #expect(try Parser.configuration(bytes).sites[0].supported == false)
    }
}
