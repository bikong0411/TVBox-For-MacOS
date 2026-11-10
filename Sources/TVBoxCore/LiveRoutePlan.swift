import Foundation

/// A finite pass through one channel's distinct routes, starting with the user's choice.
public struct LiveRoutePlan: Sendable {
    public let episodes: [Episode]
    public private(set) var currentIndex: Int?
    public private(set) var attemptedCount = 0
    public let routeCount: Int
    private var pending: [Int]
    public init(episodes: [Episode], startingAt index: Int) {
        self.episodes = episodes
        let first = episodes.indices.contains(index) ? index : 0
        var seen = Set<String>()
        var order: [Int] = []
        if !episodes.isEmpty {
            for offset in episodes.indices {
                let position = (first + offset) % episodes.count
                let url = episodes[position].url.trimmingCharacters(in: .whitespacesAndNewlines)
                if !url.isEmpty && seen.insert(url).inserted { order.append(position) }
            }
        }
        pending = order; routeCount = order.count
    }
    /// Exhaustion returns nil permanently. A new channel or manual retry creates a new plan.
    public mutating func next() -> Int? {
        guard !pending.isEmpty else { return nil }
        let index = pending.removeFirst(); currentIndex = index; attemptedCount += 1; return index
    }
}
