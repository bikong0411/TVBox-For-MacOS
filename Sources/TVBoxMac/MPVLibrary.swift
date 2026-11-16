import AppKit
import Darwin
import MPVBridge
import TVBoxCore

/// Reuse the installed playback library, never the IINA application process.
@MainActor enum MPVLibrary {
    private static var dependencies: [UnsafeMutableRawPointer] = []
    private static var loaded = false
    static var componentURL: URL? {
        let apps = [NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.colliderli.iina"), URL(fileURLWithPath: "/Applications/IINA.app"), FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications/IINA.app")]
        return apps.compactMap { $0 }.filter { Bundle(url: $0)?.bundleIdentifier == "com.colliderli.iina" }
            .map { $0.appendingPathComponent("Contents/Frameworks/libmpv.2.dylib") }
            .first { FileManager.default.fileExists(atPath: $0.path) }
    }
    static func load() throws {
        if loaded { return }
        guard let path = componentURL else { throw TVError.message("没有找到 IINA 的播放组件，将使用内置 VLC。") }
        var pending = (try? FileManager.default.contentsOfDirectory(at: path.deletingLastPathComponent(), includingPropertiesForKeys: nil)) ?? []
        // IINA normally supplies @rpath. Resolve sibling media dependencies
        // without changing either app or loading a second Swift runtime.
        pending = pending.filter { $0.pathExtension == "dylib" && !$0.lastPathComponent.hasPrefix("libswift") && $0 != path }
        var progressed = true
        while !pending.isEmpty && progressed {
            progressed = false
            pending.removeAll { url in
                if let handle = dlopen(url.path, RTLD_NOW | RTLD_LOCAL) { dependencies.append(handle); progressed = true; return true }
                return false
            }
        }
        guard tvmpv_load(path.path) == 0 else { throw TVError.message("IINA 组件与当前系统或架构不兼容，将使用内置 VLC。") }
        loaded = true
    }
}
