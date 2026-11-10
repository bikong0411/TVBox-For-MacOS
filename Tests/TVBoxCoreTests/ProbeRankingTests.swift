import Foundation
import Testing
@testable import TVBoxCore

@Suite struct ProbeRankingTests {
    private func target(_ id: String, kind: ProbeTargetKind = .vod, supported: Bool = true) -> ProbeTarget {
        ProbeTarget(id: id, name: id, kind: kind, url: "https://example.org/\(id)", supportedInApp: supported)
    }
    private func result(_ id: String, ms: Int, outcome: ProbeResult.Outcome = .success, status: Int? = 200) -> ProbeResult {
        ProbeResult(targetID: id, outcome: outcome, statusCode: status, milliseconds: ms, message: "测试")
    }
    @Test func successIsAscendingAndFastFailuresDoNotLeadTheList() {
        let targets = [target("slow"), target("http-error"), target("fast"), target("dns"), target("pending"), target("cancelled")]
        let results = ["slow": result("slow", ms: 150), "fast": result("fast", ms: 20),
                       "http-error": result("http-error", ms: 1, outcome: .httpError, status: 403),
                       "dns": result("dns", ms: 2, outcome: .networkError, status: nil), "cancelled": ProbeResult.cancelled("cancelled")]
        #expect(ProbeRanking.ordered(targets, results: results).map(\.id) == ["fast", "slow", "http-error", "dns", "pending", "cancelled"])
    }
    @Test func equalTimesKeepConfigurationOrder() {
        let targets = [target("z"), target("a"), target("m")]
        let results = Dictionary(uniqueKeysWithValues: targets.map { ($0.id, result($0.id, ms: 10)) })
        #expect(ProbeRanking.ordered(targets, results: results).map(\.id) == ["z", "a", "m"])
        #expect(ProbeRanking.recommendations(targets, results: results).first?.entries.map(\.id) == ["z", "a", "m"])
    }
    @Test func eachKindHasItsOwnFirstChoiceAndAtMostTwoAlternatives() {
        let targets = [target("a"), target("b"), target("c"), target("d"), target("live", kind: .live), target("child", kind: .subscription)]
        let results = ["a": result("a", ms: 30), "b": result("b", ms: 10), "c": result("c", ms: 20), "d": result("d", ms: 5), "live": result("live", ms: 80), "child": result("child", ms: 100)]
        let groups = ProbeRanking.recommendations(targets, results: results)
        #expect(groups.map(\.kind) == [.vod, .live, .subscription])
        #expect(groups[0].entries.map(\.id) == ["d", "b", "c"])
        #expect(groups[0].entries.map(\.label) == ["首选", "备选 1", "备选 2"])
        #expect(groups[1].entries.first?.rank == 1 && groups[2].entries.first?.rank == 1)
    }
    @Test func incompleteRedirectUnsupportedAndFailedItemsAreNeverRecommended() {
        let targets = [target("failure"), target("pending"), target("cancelled"), target("redirect"), target("unsupported", supported: false), target("good")]
        let results = ["failure": result("failure", ms: 0, outcome: .httpError, status: 404), "cancelled": ProbeResult.cancelled("cancelled"), "redirect": result("redirect", ms: 0, status: 302), "unsupported": result("unsupported", ms: 0), "good": result("good", ms: 100)]
        #expect(ProbeRanking.recommendations(targets, results: results).flatMap(\.entries).map(\.id) == ["good"])
        #expect(ProbeRanking.recommendations([target("pending")], results: [:]).isEmpty)
    }
    @Test func mergedAddressPrefersItsSupportedInterfaceName() throws {
        var library = SourceLibrary()
        try library.add(Configuration(name: "配置", location: "https://example.org/config", sites: [Site(key: "spider", name: "待适配", type: 3, api: "https://example.org/api"), Site(key: "cms", name: "兼容接口", type: 1, api: "https://example.org/api")]))
        let catalog = ProbeCatalog(library: library)
        #expect(catalog.targets.count == 1)
        #expect(catalog.targets[0].supportedInApp)
        #expect(catalog.targets[0].name == "配置 · 兼容接口")
        #expect(catalog.targets[0].names.count == 2)
    }
    @Test func copiedSubsetKeepsTheFullScopeRecommendationRank() {
        let item = target("backup"), result = result("backup", ms: 20)
        let text = ProbeReport.text(targets: [item], results: [item.id: result], recommendationRanks: [item.id: 2])
        #expect(text.contains("网络推荐"))
        #expect(text.contains("备选 1"))
        #expect(!text.contains("首选"))
    }
}
