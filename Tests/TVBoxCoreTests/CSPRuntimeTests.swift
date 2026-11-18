import Foundation
import Testing
@testable import TVBoxCore

@Suite struct CSPRuntimeTests {
    @Test func cspSelectionAndExtensionSurviveSourceRefreshAndRestore() throws {
        let component = try CSPComponent("https://fixture.invalid/spider.jar")
        let definition = try CSPDefinition(component: component, api: "csp_Fixture", extend: "{\"fixture\":true}")
        let site = Site(key: "fixture", name: "Fixture CSP", type: 3, api: "csp_Fixture", csp: definition)
        var library = SourceLibrary()
        let configuration = Configuration(name: "CSP", location: "https://fixture.invalid/config.json", sites: [site])
        _ = try library.add(configuration)
        #expect(library.activeVOD?.selectedSiteID == site.id)
        #expect(site.selectable && site.requiresCSP && !site.supported)
        let selection = library.selection
        let restored = try JSONDecoder().decode(SourceLibrary.self, from: JSONEncoder().encode(library))
        library = restored; library.restoreSelection(selection)
        #expect(library.activeVOD?.runtimeSite(site.key)?.csp == definition)
        _ = try library.add(configuration, activate: false)
        #expect(library.activeVOD?.selectedSiteID == site.id)
    }
    @Test func unavailableRuntimeFailsBeforeLaunchingAnyProcess() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let runtime = CSPBundledRuntime(assets: root, storage: root.appendingPathComponent("data"))
        #expect(!runtime.available)
        await #expect(throws: (any Error).self) { try await runtime.connection(componentHash: String(repeating: "a", count: 64)) }
        #expect(!FileManager.default.fileExists(atPath: root.path))
        runtime.stop()
    }
    @Test(.enabled(if: ProcessInfo.processInfo.environment["TVBOX_CSP_TEST_ASSETS"] != nil))
    func actualBundledRuntimeLoadsComponentThroughSwiftTransport() async throws {
        let environment = ProcessInfo.processInfo.environment
        let assets = URL(fileURLWithPath: try #require(environment["TVBOX_CSP_TEST_ASSETS"]))
        let jar = URL(fileURLWithPath: try #require(environment["TVBOX_CSP_TEST_COMPONENT"]))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("tvbox-csp-integration-" + UUID().uuidString)
        let runtime = CSPBundledRuntime(assets: assets, storage: root)
        defer { runtime.stop() }
        #expect(runtime.available)
        let site = Site(key: "isolated-test::douban", name: "CSP integration", type: 3, api: "csp_NewDouBanGuard", csp: try CSPDefinition(component: CSPComponent(jar.absoluteString), api: "csp_NewDouBanGuard"))
        let service = TVService(csp: CSPRPCTransport(runtime: runtime))
        async let first = service.categories(site: site)
        async let second = service.categories(site: site)
        let categories = try await first, repeated = try await second
        #expect(!categories.isEmpty && categories == repeated)
        let catalog = try await service.catalog(site: site)
        #expect(!catalog.videos.isEmpty)
        let fixture = assets.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent(".build/csp-fixture/fixture.jar")
        if FileManager.default.fileExists(atPath: fixture.path) {
            let synthetic = Site(key: "isolated-test::fixture", name: "Synthetic CSP", type: 3, api: "csp_CSPFixture", headers: ["X-Fixture": "preserved"], csp: try CSPDefinition(component: CSPComponent(fixture.absoluteString), api: "csp_CSPFixture", extend: "https://fixture.invalid/public-test.mp4"))
            let page = try await service.catalog(site: synthetic)
            #expect(page.videos.count == 1 && page.categories.count == 1)
            let detail = try await service.detail(video: page.videos[0], site: synthetic)
            #expect(detail.lines[0].episodes.count == 2)
            #expect(detail.lines[0].episodes[0].url == "opaque:first$token")
            let search = try await service.catalog(site: synthetic, search: "演示")
            #expect(search.videos.count == 1)
            let playback = try await service.resolvePlayback(site: synthetic, line: detail.lines[0], episode: detail.lines[0].episodes[0])
            #expect(playback.url.absoluteString == "https://fixture.invalid/public-test.mp4")
            #expect(playback.headers["User-Agent"] == "TVBoxCSPFixture" && playback.headers["X-Fixture"] == "preserved")
        }
    }
}
