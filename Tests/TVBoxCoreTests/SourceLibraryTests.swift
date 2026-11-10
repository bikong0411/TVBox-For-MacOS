import Foundation
import Testing
@testable import TVBoxCore

@Suite struct SourceLibraryTests {
    private func vod(_ name: String, suffix: String) -> Configuration {
        Configuration(name: name, location: "https://example.org/\(suffix).json", sites: [Site(key: "a", name: "接口 A", type: 1, api: "https://example.org/api/a"), Site(key: "b", name: "接口 B", type: 1, api: "https://example.org/api/b")])
    }
    private func live(_ name: String, suffix: String) -> Configuration {
        Configuration(name: name, location: "https://example.org/\(suffix).m3u", channels: [Channel(name: name, urls: ["https://example.org/\(suffix).m3u8"])])
    }
    @Test func addingLivePreservesVODAndRememberedInterface() throws {
        var library = SourceLibrary()
        try library.add(vod("点播一", suffix: "vod1"), target: .vod)
        library.selectSite("b")
        let vodID = library.selectedVODID
        try library.add(live("直播一", suffix: "live1"), target: .live)
        try library.add(live("直播二", suffix: "live2"), target: .live)
        #expect(library.selectedVODID == vodID)
        #expect(library.activeVOD?.selectedSiteID == "b")
        #expect(library.liveSources.count == 2)
        #expect(library.activeLive?.name == "直播二")
        library.selectLive(library.liveSources[0].id)
        #expect(library.activeLive?.channels.first?.name == "直播一")
        #expect(library.selectedVODID == vodID)
    }
    @Test func switchingVODPreservesLiveAndRestoresEachSite() throws {
        var library = SourceLibrary()
        try library.add(live("直播", suffix: "live"), target: .live)
        let liveID = library.selectedLiveID
        try library.add(vod("点播一", suffix: "one"), target: .vod)
        library.selectSite("b"); let first = library.selectedVODID!
        try library.add(vod("点播二", suffix: "two"), target: .vod)
        #expect(library.activeVOD?.selectedSiteID == "a")
        library.selectVOD(first)
        #expect(library.activeVOD?.selectedSiteID == "b")
        #expect(library.selectedLiveID == liveID)
    }
    @Test func combinedConfigurationSplitsLiveFeedsForIndividualSelection() throws {
        var config = vod("综合配置", suffix: "combined")
        config.feeds = [LiveFeed(name: "直播 A", url: "https://example.org/a.m3u"), LiveFeed(name: "直播 B", url: "https://example.org/b.m3u")]
        var library = SourceLibrary(); try library.add(config)
        #expect(library.vodSources.count == 1)
        #expect(library.liveSources.count == 2)
        #expect(library.activeLive?.feeds.count == 1)
        #expect(library.activeLive?.feeds.first?.name == "直播 A")
        library.selectLive(library.liveSources[1].id)
        #expect(library.activeLive?.feeds.first?.name == "直播 B")
    }
    @Test func reimportUpdatesWithoutDuplicatesOrLosingCustomName() throws {
        var library = SourceLibrary()
        var config = vod("默认名", suffix: "same")
        try library.add(config, name: "我的点播")
        let id = library.selectedVODID
        library.selectSite("b")
        config.name = "接口改名"
        try library.add(config, activate: false)
        #expect(library.vodSources.count == 1)
        #expect(library.selectedVODID == id)
        #expect(library.activeVOD?.name == "我的点播")
        #expect(library.activeVOD?.selectedSiteID == "b")
    }
    @Test func mismatchedImportIsAtomic() throws {
        var library = SourceLibrary(); try library.add(vod("点播", suffix: "vod"))
        let before = library.selectedVODID
        do { try library.add(live("直播", suffix: "live"), target: .vod); Issue.record("Must reject a live-only VOD import") } catch {}
        #expect(library.vodSources.count == 1)
        #expect(library.liveSources.isEmpty)
        #expect(library.selectedVODID == before)
    }
    @Test func legacyMigrationAndRoundTripPreserveBothSelections() throws {
        var config = vod("旧配置", suffix: "legacy")
        config.feeds = [LiveFeed(name: "旧直播", url: "https://example.org/live.m3u")]
        let library = SourceLibrary.migrating(config, siteID: "b")
        let restored = try JSONDecoder().decode(SourceLibrary.self, from: JSONEncoder().encode(library))
        #expect(restored.activeVOD?.selectedSiteID == "b")
        #expect(restored.activeLive?.name == "旧直播")
        #expect(restored.selectedVODID == library.selectedVODID)
        #expect(restored.selectedLiveID == library.selectedLiveID)
    }
    @Test func removingActiveSourceFallsBackOnlyInItsOwnSection() throws {
        var library = SourceLibrary()
        try library.add(vod("点播", suffix: "vod"))
        try library.add(live("直播一", suffix: "one"))
        try library.add(live("直播二", suffix: "two"))
        let vodID = library.selectedVODID
        library.removeLive(library.selectedLiveID!)
        #expect(library.activeLive?.name == "直播一")
        #expect(library.selectedVODID == vodID)
        library.removeVOD(vodID!)
        #expect(library.activeVOD == nil)
        #expect(library.activeLive?.name == "直播一")
    }
    @Test func targetedImportsDoNotModifyTheOtherHalfOfCombinedConfig() throws {
        var config = vod("综合", suffix: "combined")
        config.feeds = [LiveFeed(name: "直播", url: "https://example.org/live.m3u")]
        var library = SourceLibrary()
        try library.add(config, target: .vod)
        #expect(library.liveSources.isEmpty)
        try library.add(config, target: .live)
        #expect(library.vodSources.count == 1)
        #expect(library.liveSources.count == 1)
    }
    @Test func refreshingLiveOriginRemovesStaleFeedsButKeepsOtherOrigins() throws {
        var config = Configuration(name: "订阅", location: "https://example.org/config.json", feeds: [LiveFeed(name: "旧频道", url: "https://example.org/old.m3u")])
        var library = SourceLibrary(); try library.add(config)
        try library.add(live("独立直播", suffix: "independent"))
        let selected = library.selectedLiveID
        config.feeds = [LiveFeed(name: "新频道", url: "https://example.org/new.m3u")]
        try library.add(config, activate: false)
        #expect(library.liveSources.count == 2)
        #expect(library.selectedLiveID == selected)
        #expect(!library.liveSources.contains { $0.feedURL == "https://example.org/old.m3u" })
    }
    @Test func matchingKeysAcrossConfigurationsDoNotCollideInTheLibrary() throws {
        var library = SourceLibrary()
        try library.add(vod("一", suffix: "one"))
        try library.add(vod("二", suffix: "two"))
        let video = Video(id: "42", title: "同名影片")
        let first = LibraryEntry(video: video, site: library.vodSources[0].runtimeSite("a"))
        let second = LibraryEntry(video: video, site: library.vodSources[1].runtimeSite("a"))
        #expect(first.id != second.id)
    }
    @Test func existingFavoritesAndProgressAreScopedWithoutLosingData() throws {
        let config = vod("旧源", suffix: "legacy")
        let library = SourceLibrary.migrating(config)
        let old = LibraryEntry(video: Video(id: "42", title: "旧收藏"), site: config.sites[0], position: 123)
        let result = library.scopeLegacyEntries([old], legacyLocation: config.location)
        #expect(result[0].site?.key == library.activeVOD?.runtimeSite("a")?.key)
        #expect(result[0].position == 123)
        #expect(result[0].updated == old.updated)
        #expect(library.scopeLegacyEntries(result, legacyLocation: config.location)[0].id == result[0].id)
    }
    @Test func addingUnsupportedConfigurationPreservesExistingWorkingVOD() throws {
        var library = SourceLibrary(); try library.add(vod("可用点播", suffix: "working"))
        let active = library.selectedVODID
        let spider = Configuration(name: "爬虫配置", location: "https://example.org/spider", sites: [Site(key: "jar", name: "JAR", type: 3, api: "csp_Demo")], feeds: [LiveFeed(name: "直播", url: "https://example.org/live.m3u")])
        try library.add(spider)
        #expect(library.vodSources.count == 2)
        #expect(library.selectedVODID == active)
        #expect(library.liveSources.count == 1)
    }
    @Test func unsupportedSourceCanStillBeChosenExplicitly() throws {
        var library = SourceLibrary(); try library.add(vod("可用点播", suffix: "working"))
        try library.add(Configuration(name: "爬虫", location: "https://example.org/spider", sites: [Site(key: "jar", name: "JAR", type: 3, api: "csp_Demo")]))
        let selected = library.selectVOD(library.vodSources[1].id)
        #expect(selected)
        #expect(library.activeVOD?.name == "爬虫")
    }
}
