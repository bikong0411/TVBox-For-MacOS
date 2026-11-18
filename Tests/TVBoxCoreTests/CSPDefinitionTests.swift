import Foundation
import Testing
@testable import TVBoxCore

@Suite struct CSPDefinitionTests {
    @Test func retainsGlobalAndPerSiteComponentsAndStructuredExtension() throws {
        let data = Data(#"{"spider":"./worker.jar;md5;0123456789abcdef0123456789ABCDEF","sites":[{"key":"one","type":3,"api":"csp_Demo","ext":{"key":"value","urls":["https://example.invalid/"]}},{"key":"two","type":3,"api":"csp_Other","jar":"https://other.invalid/worker.jar","ext":"opaque-extension"}]}"#.utf8)
        let configuration = try Parser.configuration(data, base: URL(string: "https://source.invalid/config/index.json"))
        let first = try #require(configuration.sites[0].csp)
        #expect(first.component.url.absoluteString == "https://source.invalid/config/worker.jar")
        #expect(first.component.digest == "0123456789abcdef0123456789abcdef")
        #expect(first.className == "com.github.catvod.spider.Demo")
        let ext = try JSONSerialization.jsonObject(with: Data(first.extend.utf8)) as! [String: Any]
        #expect(ext["key"] as? String == "value")
        #expect(configuration.sites[1].csp?.component.url.host == "other.invalid")
        #expect(configuration.sites[1].csp?.extend == "opaque-extension")
        let restored = try JSONDecoder().decode(Configuration.self, from: JSONEncoder().encode(configuration))
        #expect(restored == configuration)
    }
    @Test func oldSavedSitesStillDecode() throws {
        let data = Data(#"{"key":"old","name":"old","type":1,"api":"https://example.invalid/api","searchable":true,"headers":{}}"#.utf8)
        let site = try JSONDecoder().decode(Site.self, from: data)
        #expect(site.csp == nil && site.supported)
    }
    @Test func rejectsInvalidChecksumsAndClassNames() throws {
        for raw in ["https://example.invalid/a.jar;md5;bad", "https://example.invalid/a.jar;sha256;0123", "https://example.invalid/a.jar;unknown;value", "javascript:alert(1)"] {
            #expect(throws: (any Error).self) { try CSPComponent(raw) }
        }
        let component = try CSPComponent("https://example.invalid/a.jar")
        for api in ["csp_../Runtime", "java.lang.Runtime", "csp_Demo;exec", "csp_"] {
            #expect(throws: (any Error).self) { try CSPDefinition(component: component, api: api) }
        }
    }
    @Test func spiderPlaybackIDsStayOpaqueWhileCMSURLsStillResolve() throws {
        let data = Data(#"{"list":[{"vod_id":"video-id","vod_name":"Fixture","vod_play_from":"线路一","vod_play_url":"第1集$opaque$token#第2集$cloud://folder/item"}]}"#.utf8)
        let base = URL(string: "https://source.invalid/config.json")!
        let spider = try Parser.catalog(data, base: base, resolveEpisodeURLs: false)
        #expect(spider.videos[0].lines[0].episodes.map(\.url) == ["opaque$token", "cloud://folder/item"])
        let cms = try Parser.catalog(data, base: base)
        #expect(cms.videos[0].lines[0].episodes[0].url == "https://source.invalid/opaque$token")
    }
}
