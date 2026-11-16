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
    @Test func editingVODKeepsIdentitySelectionsAndOtherSources() throws {
        var library = SourceLibrary()
        try library.add(vod("第一源", suffix: "first"), target: .vod)
        library.selectSite("b"); let id = library.selectedVODID!
        let oldHistoryKey = LibraryEntry(video: Video(id: "42", title: "历史"), site: library.activeVOD?.runtimeSite("b")).id
        try library.add(vod("另一个源", suffix: "other"), target: .vod, activate: false)
        try library.add(live("直播", suffix: "live"), target: .live)
        let other = library.vodSources[1], liveBefore = library.liveSources, selection = library.selection
        try library.replaceVOD(id, configuration: vod("远端名", suffix: "new"), name: " 修改后的名称 ")
        #expect(library.vodSources.count == 2)
        #expect(library.activeVOD?.id == id)
        #expect(library.activeVOD?.name == "修改后的名称")
        #expect(library.activeVOD?.origin == "https://example.org/new.json")
        #expect(library.activeVOD?.selectedSiteID == "b")
        #expect(library.vodSources[1] == other && library.liveSources == liveBefore)
        #expect(library.selection.vodID == selection.vodID && library.selection.liveID == selection.liveID)
        #expect(LibraryEntry(video: Video(id: "42", title: "历史"), site: library.activeVOD?.runtimeSite("b")).id == oldHistoryKey)
    }
    @Test func editingInactiveVODDoesNotActivateAndFallsBackToValidInterface() throws {
        var library = SourceLibrary()
        try library.add(vod("第一", suffix: "first")); let first = library.selectedVODID!
        library.selectSite("b")
        try library.add(vod("当前", suffix: "active")); let active = library.selectedVODID
        let replacement = Configuration(location: "https://example.org/replacement.json", sites: [Site(key: "new", name: "新接口", type: 1, api: "https://example.org/api")])
        try library.replaceVOD(first, configuration: replacement, name: "改名")
        #expect(library.selectedVODID == active)
        #expect(library.vodSources[0].selectedSiteID == "new")
    }
    @Test func invalidAndDuplicateVODEditsLeaveOriginalUntouched() throws {
        var library = SourceLibrary()
        try library.add(vod("一", suffix: "one")); let id = library.selectedVODID!
        try library.add(vod("二", suffix: "two"))
        let before = library.vodSources
        for config in [live("直播", suffix: "wrong"), vod("重复", suffix: "two")] {
            do { try library.replaceVOD(id, configuration: config, name: "不能保存"); Issue.record("Invalid edit accepted") } catch {}
            #expect(library.vodSources == before)
        }
        do { try library.replaceVOD("missing", configuration: vod("新", suffix: "new"), name: "失效"); Issue.record("Removed source reappeared") } catch {}
        #expect(library.vodSources == before)
    }
    @Test func editingOneLiveSubscriptionPreservesSiblingsMetadataAndVOD() throws {
        var library = SourceLibrary()
        let old = LiveFeed(name: "旧订阅", url: "https://example.org/old.m3u", headers: ["Authorization": "fixture-only"], guide: LiveGuideInfo(url: "https://example.org/epg.xml"))
        let sibling = LiveFeed(name: "同配置的另一条", url: "https://example.org/sibling.m3u")
        try library.add(Configuration(location: "https://example.org/combined.json", sites: vod("点播", suffix: "vod").sites, feeds: [old, sibling]))
        let id = library.liveSources[0].id, siblingBefore = library.liveSources[1], vodBefore = library.vodSources
        library.selectLive(siblingBefore.id)
        var feed = old; feed.url = "https://example.org/new.m3u"
        try library.replaceLive(id, configuration: Configuration(location: feed.url, feeds: [feed]), name: "新直播")
        #expect(library.liveSources.count == 2 && library.liveSources[1] == siblingBefore)
        #expect(library.selectedLiveID == siblingBefore.id && library.vodSources == vodBefore)
        #expect(library.liveSources[0].id == id && library.liveSources[0].feedURL == feed.url)
        #expect(library.liveSources[0].origin == feed.url)
        #expect(library.liveSources[0].feeds[0].headers == old.headers && library.liveSources[0].feeds[0].guide == old.guide)
        let restored = try JSONDecoder().decode(SourceLibrary.self, from: JSONEncoder().encode(library))
        #expect(restored.liveSources == library.liveSources)
    }
    @Test func liveEditRejectsAmbiguityAndDuplicatesAtomically() throws {
        var library = SourceLibrary()
        try library.add(live("一", suffix: "one")); let id = library.selectedLiveID!
        try library.add(live("二", suffix: "two")); let before = library.liveSources
        let ambiguous = Configuration(location: "https://example.org/multi.json", feeds: [
            LiveFeed(name: "A", url: "https://example.org/a.m3u"),
            LiveFeed(name: "B", url: "https://example.org/b.m3u")])
        for config in [ambiguous, vod("错误类型", suffix: "vod"), live("重复", suffix: "two")] {
            do { try library.replaceLive(id, configuration: config, name: "不能保存"); Issue.record("Invalid live edit accepted") } catch {}
            #expect(library.liveSources == before)
        }
    }
}
