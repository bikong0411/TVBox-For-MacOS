import Foundation

public enum PlaybackPreference: String, CaseIterable, Identifiable, Sendable {
    case preferIINA, builtIn
    public var id: String { rawValue }
    public var title: String { self == .preferIINA ? "优先 IINA 播放组件（软件内播放）" : "始终使用内置 VLC" }
}

