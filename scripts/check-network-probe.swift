import Foundation
import TVBoxCore

private struct CheckFailure: Error { var message: String }

@main struct ProbeCheck {
    @MainActor static func main() async {
        do {
            guard CommandLine.arguments.count == 2, let url = URL(string: CommandLine.arguments[1]), url.host == "127.0.0.1" else { throw CheckFailure(message: "Use the local fixture-server /probe-config.json URL") }
            let configuration = try await TVService().configuration(at: url)
            var library = SourceLibrary(); try library.add(configuration)
            let model = NetworkProbeModel(); await model.prepare(library)
            try require(model.targets.count == 9 && model.skippedCount == 1, "Target collection or deduplication failed")
            model.timeout = 3; model.concurrency = 3; model.start()
            try await wait(model)
            for target in model.targets {
                if let result = model.results[target.id] { print("CHECK: \(target.name) | \(result.statusCode.map(String.init) ?? result.message) | \(result.method) | \(result.milliseconds) ms") }
            }
            try require(model.completed == 9 && model.successCount == 6 && model.failureCount == 3, "Incorrect batch summary: \(model.completed), normal \(model.successCount), failed \(model.failureCount)")
            let ordered = ProbeRanking.ordered(model.targets, results: model.results)
            let normal = Array(ordered.prefix(model.successCount))
            let times = normal.compactMap { model.results[$0.id]?.milliseconds }
            try require(normal.allSatisfy { model.results[$0.id]?.outcome == .success } && times == times.sorted(), "Response-time ordering failed")
            try require(model.recommendations.count == 3 && model.recommendations.allSatisfy { $0.entries.first?.rank == 1 && $0.entries.count <= 3 }, "Per-kind recommendations missing")
            let feed = library.liveSources[0].feeds[0]
            try require(model.result(url: feed.url, kind: .live, headers: feed.headers)?.outcome == .success, "Subscription latency lookup failed")
            let site = library.vodSources[0].configuration.sites[0]
            let lowerHeaders = Dictionary(uniqueKeysWithValues: site.headers.map { ($0.key.lowercased(), $0.value) })
            try require(model.result(url: site.api, kind: .vod, headers: lowerHeaders)?.outcome == .success, "Case-insensitive interface lookup failed")
            try require(model.result(url: site.api, kind: .vod, headers: ["Authorization": "different"]) == nil, "Latency incorrectly reused another authorization")
            try require(model.result(url: site.api + "&changed=1", kind: .vod, headers: site.headers) == nil, "Latency incorrectly reused another URL")
            print("PASS: source latency lookup matches URL, type and headers; changed URLs or credentials do not reuse results")
            func target(_ path: String) throws -> ProbeTarget {
                guard let target = model.targets.first(where: { URL(string: $0.url)?.path == path }) else { throw CheckFailure(message: "Missing fixture target") }; return target
            }
            let headers = try target("/probe-headers-only")
            try require(model.results[headers.id]?.statusCode == 200 && model.results[headers.id]?.method == "GET" && (model.results[headers.id]?.milliseconds ?? 99999) < 1500, "GET probe waited for the complete large body")
            let redirect = try target("/probe-redirect"), slow = try target("/probe-slow")
            try require(model.results[redirect.id]?.statusCode == 200, "Redirect handling failed")
            try require(model.results[slow.id]?.message == "连接超时", "Real timeout classification failed")
            let report = ProbeReport.text(targets: model.targets, results: model.results)
            try require(!report.contains("private-test") && !report.contains("Bearer"), "Report contains URL credentials or headers")
            print("PASS: 9 configured addresses; 1 non-HTTP skipped; 6 normal / 3 failed; redirects, GET fallback, early completion without a full body, and real timeout")
            let successes = model.results.filter { $0.value.outcome == .success }
            await model.prepare(library)
            try require(model.results.count == 9, "Results lost after refreshing unchanged configuration")
            model.start(failuresOnly: true)
            try require(model.total == 3, "Retry included successful addresses")
            try await wait(model)
            try require(successes.allSatisfy { model.results[$0.key] == $0.value }, "Successful results changed during retry")
            print("PASS: retry failures only; successful results retained")
            model.start()
            for _ in 0..<100 {
                if model.activeIDs.contains(slow.id) { break }
                try await Task.sleep(nanoseconds: 10_000_000)
            }
            try require(model.activeIDs.contains(slow.id), "Slow fixture never started")
            model.cancel()
            try require(!model.isRunning && model.stopped && model.activeIDs.isEmpty && model.queuedIDs.isEmpty, "Cancellation did not clear running state")
            model.kind = .live; model.start(); try await wait(model)
            try await Task.sleep(nanoseconds: 300_000_000)
            try require(model.total == 1 && model.completed == 1 && model.successCount == 1 && !model.isRunning, "Old batch modified the new run")
            print("PASS: cancellation, scope selection and immediate restart ignore obsolete results")
            let sortURL = url.deletingLastPathComponent().appendingPathComponent("live-sort-config.json")
            var sortConfig = try await TVService().configuration(at: sortURL)
            var liveLibrary = SourceLibrary(); try liveLibrary.add(sortConfig)
            let selected = liveLibrary.selectedLiveID
            let originalIDs = liveLibrary.liveSources.map(\.id)
            let liveModel = NetworkProbeModel(); await liveModel.prepare(liveLibrary)
            liveModel.kind = .live; liveModel.timeout = 3; liveModel.start(); try await wait(liveModel)
            sortConfig.feeds.append(LiveFeed(name: "未探测直播", url: url.deletingLastPathComponent().appendingPathComponent("probe-sort-unchecked.m3u").absoluteString))
            try liveLibrary.add(sortConfig, target: .live, activate: false); await liveModel.prepare(liveLibrary)
            let sortedSources = liveModel.orderedLiveSources(liveLibrary.liveSources, byLatency: true)
            try require(sortedSources.map(\.name) == ["快速直播", "慢速直播", "失败直播", "未探测直播"], "Live sources are not sorted by measured latency")
            try require(liveModel.orderedLiveSources(liveLibrary.liveSources, byLatency: false).map(\.id) == liveLibrary.liveSources.map(\.id), "Original source order was not restored")
            try require(liveLibrary.selectedLiveID == selected && Array(liveLibrary.liveSources.prefix(3)).map(\.id) == originalIDs, "Sorting changed selected source or saved source order")
            print("PASS: live sources sort fast / slow / failed / unmeasured; original order and selected source remain unchanged")
        } catch {
            print("FAIL: \((error as? CheckFailure)?.message ?? "\((error as NSError).domain) (\((error as NSError).code))")"); exit(1)
        }
    }
    @MainActor private static func require(_ value: Bool, _ message: String) throws { if !value { throw CheckFailure(message: message) } }
    @MainActor private static func wait(_ model: NetworkProbeModel) async throws {
        for _ in 0..<240 {
            if !model.isRunning { return }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        model.cancel(); throw CheckFailure(message: "Batch did not finish within 12 seconds")
    }
}
