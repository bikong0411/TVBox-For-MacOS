import Foundation
import Testing
@testable import TVBoxCore

@Suite struct UIPerformanceTests {
    private func combined() -> Configuration {
        Configuration(name: "综合", location: "https://example.org/config", sites: (0..<100).map { Site(key: "s\($0)", name: "源", type: 1, api: "https://example.org/api/\($0)") }, feeds: (0..<12).map { LiveFeed(name: "直播 \($0)", url: "https://example.org/live/\($0)") }, channels: [Channel(name: "内嵌", urls: ["https://example.org/live.m3u8"])])
    }
    @Test func entriesStoreOnlyTheirOwnPayload() throws {
        var library = SourceLibrary(); try library.add(combined())
        #expect(library.vodSources[0].configuration.feeds.isEmpty)
        #expect(library.vodSources[0].configuration.channels.isEmpty)
        #expect(library.liveSources.count == 13)
        #expect(library.liveSources.allSatisfy { $0.configuration.sites.isEmpty })
        #expect(library.liveSources[0].feeds.count == 1)
        #expect(library.liveSources.last?.channels.count == 1)
    }
    @Test func legacyPayloadCompactionPreservesIDsAndSelectedContent() throws {
        let config = combined(); var library = SourceLibrary(); try library.add(config)
        let payload = try JSONSerialization.jsonObject(with: JSONEncoder().encode(config))
        var object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(library)) as! [String: Any]
        for key in ["vodSources", "liveSources"] {
            var entries = object[key] as! [[String: Any]]
            for i in entries.indices { entries[i]["configuration"] = payload }
            object[key] = entries
        }
        let old = try JSONSerialization.data(withJSONObject: object)
        var restored = try JSONDecoder().decode(SourceLibrary.self, from: old)
        let ids = restored.liveSources.map(\.id), selected = restored.selectedLiveID
        let compacted = restored.compactPayloads(); #expect(compacted)
        #expect(restored.liveSources.map(\.id) == ids)
        #expect(restored.selectedLiveID == selected)
        #expect(restored.activeLive?.feeds.first?.url == library.activeLive?.feeds.first?.url)
        let again = restored.compactPayloads(); #expect(!again)
        #expect(try JSONEncoder().encode(restored).count < old.count / 4)
    }
    @Test func separateSelectionSnapshotRestoresLatestChoices() throws {
        var library = SourceLibrary(); try library.add(combined())
        let full = try JSONEncoder().encode(library)
        library.selectLive(library.liveSources[5].id); library.selectSite("s9")
        let selection = try JSONEncoder().encode(library.selection)
        var restarted = try JSONDecoder().decode(SourceLibrary.self, from: full)
        restarted.restoreSelection(try JSONDecoder().decode(SourceSelection.self, from: selection))
        #expect(restarted.selectedLiveID == library.selectedLiveID)
        #expect(restarted.activeVOD?.selectedSiteID == "s9")
        #expect(selection.count < 500)
    }
    @Test func invalidSelectionDoesNotEraseValidSource() throws {
        var library = SourceLibrary(); try library.add(combined()); let before = library.selectedLiveID
        library.restoreSelection(SourceSelection(vodID: "missing", liveID: "missing", siteIDs: [library.vodSources[0].id: "missing"]))
        #expect(library.selectedLiveID == before)
        #expect(library.activeVOD?.selectedSiteID == "s0")
    }
    @Test func duplicateChannelsBecomeMultipleRoutesWithoutLosingURLs() {
        let index = ChannelIndex(channels: [Channel(name: " CCTV1 ", group: "央视", urls: ["https://a/1", "https://a/1"]), Channel(name: "CCTV1", group: "央视", logo: "https://a/logo", urls: ["https://a/2"]), Channel(name: "CCTV2", group: "央视", urls: ["https://a/3"])])
        #expect(index.channels.count == 2)
        #expect(index.channels[0].urls == ["https://a/1", "https://a/2"])
        #expect(index.channels[0].logo == "https://a/logo")
        #expect(index.matching(query: "cctv1").count == 1)
    }
    @Test func channelsWithDifferentHeadersOrGroupsRemainSeparate() {
        let index = ChannelIndex(channels: [Channel(name: "频道", group: "甲", urls: ["https://a/1"]), Channel(name: "频道", group: "甲", urls: ["https://a/1"], headers: ["Authorization": "x"]), Channel(name: "频道", group: "乙", urls: ["https://a/1"])])
        #expect(index.channels.count == 3)
        #expect(Set(index.channels.map(\.id)).count == 3)
        #expect(index.matching(group: "乙").count == 1)
    }
    @Test func preferenceWritesKeepFIFOOrderAndFlushOnExit() throws {
        let name = "tvbox-test-\(UUID().uuidString)"; let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let writer = PreferenceWriter(defaults: defaults)
        for value in 0..<30 { writer.save(value, key: "selected") }
        writer.flush()
        #expect(try JSONDecoder().decode(Int.self, from: defaults.data(forKey: "selected")!) == 29)
    }
}
