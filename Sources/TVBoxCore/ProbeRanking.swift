import Foundation

public struct ProbeRecommendation: Identifiable, Equatable, Sendable {
    public let target: ProbeTarget
    public let result: ProbeResult
    public let rank: Int
    public var id: String { target.id }
    public var label: String { rank == 1 ? "首选" : "备选 \(rank - 1)" }
}

public struct ProbeRecommendationGroup: Identifiable, Equatable, Sendable {
    public let kind: ProbeTargetKind
    public let entries: [ProbeRecommendation]
    public var id: String { kind.rawValue }
}

public enum ProbeRanking {
    /// Successful responses first by elapsed time, followed by failures and unfinished items.
    /// Keep configuration order for equal times, so recommendations do not jump arbitrarily.
    public static func ordered(_ targets: [ProbeTarget], results: [String: ProbeResult]) -> [ProbeTarget] {
        orderedByResponse(targets) { results[$0.id] }
    }
    public static func orderedLiveSources(_ sources: [SavedLiveSource], results: [String: ProbeResult]) -> [SavedLiveSource] {
        orderedByResponse(sources) { results[$0.id] }
    }
    private static func orderedByResponse<Value>(_ values: [Value], result: (Value) -> ProbeResult?) -> [Value] {
        func bucket(_ result: ProbeResult?) -> Int {
            guard let result else { return 2 }
            switch result.outcome { case .success: return 0; case .httpError, .networkError: return 1; case .cancelled: return 2 }
        }
        let measured = values.enumerated().map { (offset: $0.offset, value: $0.element, result: result($0.element)) }
        return measured.sorted { lhs, rhs in
            let left = lhs.result, right = rhs.result
            let l = bucket(left), r = bucket(right)
            if l != r { return l < r }
            if l < 2, left?.milliseconds != right?.milliseconds { return (left?.milliseconds ?? Int.max) < (right?.milliseconds ?? Int.max) }
            return lhs.offset < rhs.offset
        }.map(\.value)
    }
    public static func recommendations(_ targets: [ProbeTarget], results: [String: ProbeResult], limit: Int = 3) -> [ProbeRecommendationGroup] {
        let eligible = ordered(targets, results: results).filter { target in
            guard target.supportedInApp, let result = results[target.id], result.outcome == .success, let status = result.statusCode else { return false }
            return (200..<300).contains(status) && result.milliseconds >= 0
        }
        return ProbeTargetKind.allCases.compactMap { kind in
            let candidates = eligible.filter { $0.kind == kind }.prefix(max(0, limit))
            let entries = candidates.enumerated().compactMap { offset, target -> ProbeRecommendation? in
                guard let result = results[target.id] else { return nil }
                return ProbeRecommendation(target: target, result: result, rank: offset + 1)
            }
            return entries.isEmpty ? nil : ProbeRecommendationGroup(kind: kind, entries: entries)
        }
    }
}
