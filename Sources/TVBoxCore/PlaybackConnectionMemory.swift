import Foundation

/// An in-memory hint, recorded only after the compatibility path opens media.
/// Credentials are part of the scope and are never persisted or logged.
public struct PlaybackConnectionMemory {
    private struct Header: Hashable { let name: String; let value: String }
    private struct Key: Hashable {
        let scheme: String
        let host: String
        let port: Int
        let user: String?
        let password: String?
        let headers: [Header]
        init?(_ url: URL, headers: [String: String]) {
            guard let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme),
                  let host = url.host?.lowercased(), !host.isEmpty else { return nil }
            self.scheme = scheme; self.host = host; port = url.port ?? (scheme == "https" ? 443 : 80)
            user = url.user; password = url.password
            self.headers = headers.map { Header(name: $0.key.lowercased(), value: $0.value) }
                .sorted { $0.name == $1.name ? $0.value < $1.value : $0.name < $1.name }
        }
    }
    private struct Entry { let verified: Date; var touched: Date }
    private var entries: [Key: Entry] = [:]
    private let lifetime: TimeInterval
    private let capacity: Int
    public init(lifetime: TimeInterval = 15 * 60, capacity: Int = 64) {
        self.lifetime = lifetime.isFinite ? max(0, lifetime) : 15 * 60
        self.capacity = max(0, min(256, capacity))
    }
    public mutating func prefersCompatibility(for url: URL, headers: [String: String], now: Date = Date()) -> Bool {
        prune(now)
        guard let key = Key(url, headers: headers), entries[key] != nil else { return false }
        entries[key]?.touched = now
        return true
    }
    public mutating func rememberCompatibility(for url: URL, headers: [String: String], now: Date = Date()) {
        prune(now)
        guard capacity > 0, lifetime > 0, let key = Key(url, headers: headers) else { return }
        if entries[key] == nil, entries.count >= capacity, let oldest = entries.min(by: { $0.value.touched < $1.value.touched })?.key {
            entries.removeValue(forKey: oldest)
        }
        entries[key] = Entry(verified: now, touched: now)
    }
    public mutating func forget(_ url: URL, headers: [String: String]) {
        guard let key = Key(url, headers: headers) else { return }
        entries.removeValue(forKey: key)
    }
    private mutating func prune(_ now: Date) {
        entries = entries.filter { now >= $0.value.verified && now.timeIntervalSince($0.value.verified) < lifetime }
    }
}
