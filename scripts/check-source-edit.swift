import AppKit
import Foundation
import TVBoxCore

@main struct CheckSourceEdit {
    @MainActor static func require(_ value: @autoclosure () -> Bool, _ text: String) throws {
        if !value() { throw TVError.message(text) }
    }
    @MainActor static func main() async {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let store = AppStore()
        let base = "http://127.0.0.1:18791"
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally(); store.shutdown() }
        do {
            let a = try await store.service.configuration(at: URL(string: base + "/config-a.json")!)
            try store.apply(a, target: .vod, name: "原点播")
            store.selectSite("backup")
            let vodID = store.sourceLibrary.selectedVODID!
            let before = store.sourceLibrary
            do {
                try await store.updateSource(vodID, live: false, name: "错误", address: base + "/missing.json")
                throw TVError.message("Invalid source was saved")
            } catch {
                try require(store.vodSources == before.vodSources, "Failed edit changed the source")
            }
            try await store.updateSource(vodID, live: false, name: "新点播", address: base + "/config-b.json")
            try require(store.vodSources.count == 1 && store.selectedVODSource?.id == vodID && store.siteID == "backup", "VOD edit lost identity or interface selection")
            try require(store.sourceAddress(vodID, live: false) == base + "/config-b.json", "VOD URL did not change")

            // A name-only edit must work even when the origin is unreachable.
            var offline = a
            offline.location = "https://user:fixture@offline.invalid/config.json?token=keep%2Bexact#fragment"
            try store.apply(offline, target: .vod)
            let offlineID = store.sourceLibrary.selectedVODID!
            try await store.updateSource(offlineID, live: false, name: "离线改名", address: offline.location)
            store.copySourceAddress(offlineID, live: false, pasteboard: board)
            try require(store.selectedVODSource?.name == "离线改名" && board.string(forType: .string) == offline.location, "Offline rename or full URL copy failed")
            print("PASS: failed VOD edit rollback, stable identity/interface, offline rename and exact clipboard URL")

            let guide = LiveGuideInfo(url: base + "/overlay-guide.xml")
            let first = LiveFeed(name: "直播 A", url: base + "/edit-live-a.m3u", headers: ["X-Source-Edit": "fixture-preserved"], guide: guide)
            let sibling = LiveFeed(name: "直播 B", url: base + "/live-b.m3u")
            try store.apply(Configuration(name: "直播配置", location: base + "/feed-config.json", feeds: [first, sibling]), target: .live)
            let liveID = store.liveSources[0].id, siblingID = store.liveSources[1].id
            store.selectLiveSource(siblingID)
            let vodBefore = store.vodSources, liveSelection = store.sourceLibrary.selectedLiveID
            let siblingBefore = store.liveSources[1]
            try await store.updateSource(liveID, live: true, name: "新直播 A", address: base + "/edit-live-b.m3u?token=complete")
            try require(store.liveSources.count == 2 && store.sourceLibrary.selectedLiveID == liveSelection, "Inactive live edit changed selection")
            try require(store.vodSources == vodBefore && store.liveSources[1] == siblingBefore, "Live edit changed another source")
            let updated = store.liveSources[0]
            try require(updated.id == liveID && updated.feeds.first?.headers == first.headers && updated.feeds.first?.guide == guide, "Live edit dropped headers/EPG or identity")
            store.copySourceAddress(liveID, live: true, pasteboard: board)
            try require(board.string(forType: .string) == base + "/edit-live-b.m3u?token=complete", "Live copy dropped URL parameters")
            await store.refreshSource(liveID, live: true)
            try require(store.liveSources[0] == updated && store.sourceLibrary.selectedLiveID == liveSelection, "Refreshing edited subscription changed identity, headers or selection")
            print("PASS: independent live subscription edit preserves authentication, EPG, siblings and selections")

            let stable = store.vodSources
            let cancelled = Task { @MainActor in
                try await store.updateSource(vodID, live: false, name: "不应保存", address: base + "/edit-slow.json?cancel=1")
            }
            try await Task.sleep(nanoseconds: 100_000_000)
            cancelled.cancel()
            do { try await cancelled.value; throw TVError.message("Cancelled edit completed") }
            catch is CancellationError {}
            try require(store.vodSources == stable, "Cancelled edit changed configuration")
            let removed = Task { @MainActor in
                try await store.updateSource(vodID, live: false, name: "不能复活", address: base + "/edit-slow.json?removed=1")
            }
            try await Task.sleep(nanoseconds: 100_000_000)
            store.removeSource(vodID, live: false)
            do { try await removed.value; throw TVError.message("Removed source was saved") }
            catch {
                try require(!store.vodSources.contains { $0.id == vodID }, "Late response resurrected a removed source")
            }

            let stale = Task { @MainActor in
                try await store.updateSource(offlineID, live: false, name: "过期编辑", address: base + "/edit-slow.json?stale=1")
            }
            try await Task.sleep(nanoseconds: 100_000_000)
            var imported = offline; imported.sites[0].name = "较新的配置"
            try store.apply(imported, target: .vod, name: "较新的配置")
            do { try await stale.value; throw TVError.message("Stale edit overwrote newer import") }
            catch {
                try require(store.selectedVODSource?.name == "较新的配置" && store.selectedVODSource?.configuration.sites[0].name == "较新的配置", "Newer import was overwritten")
            }
            try require(store.refreshingSources.isEmpty, "Busy state was not cleared")
            print("PASS: cancellation, removal and concurrent import cannot commit stale source edits")
            print("ALL SOURCE EDIT CHECKS PASSED")
        } catch {
            fputs("FAIL: " + error.localizedDescription + "\n", stderr); exit(1)
        }
    }
}
