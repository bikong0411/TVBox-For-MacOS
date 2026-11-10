import Foundation

/// FIFO writes off the UI thread; callers flush only when terminating the app.
public final class PreferenceWriter: @unchecked Sendable {
    private let defaults: UserDefaults
    private let queue = DispatchQueue(label: "local.tvboxmac.preferences", qos: .utility)
    private let key = DispatchSpecificKey<Bool>()
    public init(defaults: UserDefaults) { self.defaults = defaults; queue.setSpecific(key: key, value: true) }
    public func save<T: Encodable & Sendable>(_ value: T, key: String) {
        queue.async { [defaults] in
            if let data = try? JSONEncoder().encode(value) { defaults.set(data, forKey: key) }
        }
    }
    public func flush() { if DispatchQueue.getSpecific(key: key) == nil { queue.sync {} } }
}
