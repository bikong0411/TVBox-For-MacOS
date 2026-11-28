public struct VODRecentCache<Key: Hashable, Value> {
    private struct Entry {
        let value: Value
        let expires: ContinuousClock.Instant
        var lastUsed: ContinuousClock.Instant
    }

    private let limit: Int
    private let lifetime: Duration
    private var entries: [Key: Entry] = [:]

    public init(limit: Int, lifetime: Duration) {
        precondition(limit > 0)
        self.limit = limit
        self.lifetime = lifetime
    }

    public mutating func value(for key: Key, now: ContinuousClock.Instant = .now) -> Value? {
        guard var entry = entries[key], entry.expires > now else {
            entries.removeValue(forKey: key)
            return nil
        }
        entry.lastUsed = now
        entries[key] = entry
        return entry.value
    }

    public mutating func values(where matches: (Key) -> Bool, now: ContinuousClock.Instant = .now) -> [Value] {
        let keys = entries.keys.filter(matches)
        return keys.compactMap { value(for: $0, now: now) }
    }

    public mutating func store(_ value: Value, for key: Key, now: ContinuousClock.Instant = .now) {
        if entries[key] == nil, entries.count >= limit {
            entries = entries.filter { $0.value.expires > now }
            if entries.count >= limit, let oldest = entries.min(by: { $0.value.lastUsed < $1.value.lastUsed }) {
                entries.removeValue(forKey: oldest.key)
            }
        }
        entries[key] = Entry(value: value, expires: now + lifetime, lastUsed: now)
    }

    public mutating func remove(where matches: (Key) -> Bool) {
        entries = entries.filter { !matches($0.key) }
    }

    public mutating func removeValue(for key: Key) {
        entries.removeValue(forKey: key)
    }
}
