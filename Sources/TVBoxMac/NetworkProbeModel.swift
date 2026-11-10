import Foundation
import Combine
import TVBoxCore

@MainActor final class NetworkProbeModel: ObservableObject {
    @Published private(set) var targets: [ProbeTarget] = []
    @Published private(set) var results: [String: ProbeResult] = [:]
    @Published private(set) var activeIDs = Set<String>()
    @Published private(set) var queuedIDs = Set<String>()
    @Published private(set) var isRunning = false
    @Published private(set) var preparing = false
    @Published private(set) var skippedCount = 0
    @Published private(set) var completed = 0
    @Published private(set) var total = 0
    @Published private(set) var stopped = false
    @Published var kind: ProbeTargetKind?
    @Published var timeout = 8
    @Published var concurrency = 6
    private var task: Task<Void, Never>?
    private var generation = UUID()
    private var targetIDs: [ProbeRequestKey: String] = [:]
    var scopedTargets: [ProbeTarget] { targets.filter { kind == nil || $0.kind == kind } }
    var successCount: Int { scopedTargets.filter { results[$0.id]?.outcome == .success }.count }
    var failureCount: Int { scopedTargets.filter { results[$0.id]?.isFailure == true }.count }
    var recommendations: [ProbeRecommendationGroup] { isRunning ? [] : ProbeRanking.recommendations(scopedTargets, results: results) }
    func result(url: String, kind: ProbeTargetKind, headers: [String: String] = [:]) -> ProbeResult? {
        guard let id = targetIDs[ProbeRequestKey(kind: kind, url: url, headers: headers)] else { return nil }
        return results[id]
    }
    func liveResult(_ source: SavedLiveSource) -> ProbeResult? {
        guard let feed = source.feeds.first else { return nil }
        return result(url: feed.url, kind: .live, headers: feed.headers)
    }
    func orderedLiveSources(_ sources: [SavedLiveSource], byLatency: Bool) -> [SavedLiveSource] {
        guard byLatency else { return sources }
        let measurements = Dictionary(uniqueKeysWithValues: sources.compactMap { source in liveResult(source).map { (source.id, $0) } })
        return ProbeRanking.orderedLiveSources(sources, results: measurements)
    }
    func prepare(_ library: SourceLibrary) async {
        guard !isRunning else { return }; preparing = true
        let catalog = await Task.detached(priority: .userInitiated) { ProbeCatalog(library: library) }.value
        guard !Task.isCancelled, !isRunning else { preparing = false; return }
        let old = Dictionary(uniqueKeysWithValues: targets.map { ($0.id, $0) })
        let current = Dictionary(uniqueKeysWithValues: catalog.targets.map { ($0.id, $0) })
        results = results.filter { pair in
            guard let target = current[pair.key] else { return false }
            return old[pair.key]?.url == target.url && old[pair.key]?.headers == target.headers
        }
        targetIDs = Dictionary(uniqueKeysWithValues: catalog.targets.map { (ProbeRequestKey(kind: $0.kind, url: $0.url, headers: $0.headers), $0.id) })
        targets = catalog.targets; skippedCount = catalog.skippedCount; preparing = false
    }
    func start(failuresOnly: Bool = false) {
        guard !isRunning, !preparing else { return }
        let batch = scopedTargets.filter { !failuresOnly || results[$0.id]?.isFailure == true }
        guard !batch.isEmpty else { return }
        generation = UUID(); let token = generation
        for target in batch { results.removeValue(forKey: target.id) }
        queuedIDs = Set(batch.map(\.id)); activeIDs = []; completed = 0; total = batch.count; stopped = false; isRunning = true
        let limit = timeout, parallel = concurrency
        task = Task { [weak self] in
            await NetworkProbeRunner().run(batch, concurrency: parallel, timeout: TimeInterval(limit)) { [weak self] event in
                await self?.receive(event, token: token)
            }
            guard let self, self.generation == token else { return }
            self.isRunning = false; self.queuedIDs = []; self.activeIDs = []; self.task = nil
        }
    }
    private func receive(_ event: ProbeEvent, token: UUID) {
        guard generation == token, isRunning else { return }
        switch event {
        case .started(let id): activeIDs.insert(id)
        case .finished(let result):
            activeIDs.remove(result.targetID); queuedIDs.remove(result.targetID)
            results[result.targetID] = result; completed += 1
        }
    }
    func cancel() {
        guard isRunning else { return }
        generation = UUID(); task?.cancel(); task = nil
        for id in activeIDs { results[id] = .cancelled(id) }
        queuedIDs = []; activeIDs = []; isRunning = false; stopped = true
    }
}

