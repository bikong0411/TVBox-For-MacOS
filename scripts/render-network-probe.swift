import SwiftUI
import AppKit
import TVBoxCore

/// Render only our own fixture view into an offscreen window. No desktop capture or input.
@main struct RenderNetworkProbe {
    @MainActor static func main() async {
        do {
            guard CommandLine.arguments.contains("--ui-test"), let input = CommandLine.arguments.dropFirst().first, let url = URL(string: input), url.host == "127.0.0.1" else { exit(2) }
            let application = NSApplication.shared; application.setActivationPolicy(.prohibited)
            let store = AppStore()
            try store.apply(await store.service.configuration(at: url))
            let model = store.networkProbe; await model.prepare(store.sourceLibrary)
            model.timeout = 3; model.start()
            for _ in 0..<200 { if !model.isRunning { break }; try await Task.sleep(nanoseconds: 50_000_000) }
            guard !model.isRunning else { store.shutdown(); exit(1) }
            for width in [682, 960] {
                let content = NetworkProbeView(model: model).environmentObject(store).preferredColorScheme(.dark).tint(Theme.accent)
                    .frame(width: CGFloat(width), height: 760).background(Theme.background)
                let hosting = NSHostingView(rootView: content)
                let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 760), styleMask: .borderless, backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false; window.contentView = hosting
                try await Task.sleep(nanoseconds: 250_000_000)
                hosting.layoutSubtreeIfNeeded()
                guard !window.isVisible, let bitmap = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else { store.shutdown(); exit(1) }
                hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
                let output = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".build/probe-preview-\(width).png")
                guard let data = bitmap.representation(using: .png, properties: [:]) else { store.shutdown(); exit(1) }
                try data.write(to: output); print("Rendered offscreen fixture: \(output.path)")
                window.close()
            }
            var sortConfig = try await store.service.configuration(at: url.deletingLastPathComponent().appendingPathComponent("live-sort-config.json"))
            try store.apply(sortConfig, target: .live)
            await model.prepare(store.sourceLibrary); model.kind = .live; model.start()
            for _ in 0..<200 { if !model.isRunning { break }; try await Task.sleep(nanoseconds: 50_000_000) }
            guard !model.isRunning else { store.shutdown(); exit(1) }
            sortConfig.feeds.append(LiveFeed(name: "未探测直播", url: url.deletingLastPathComponent().appendingPathComponent("probe-sort-unchecked.m3u").absoluteString))
            try store.apply(sortConfig, target: .live); await model.prepare(store.sourceLibrary)
            if let index = CommandLine.arguments.firstIndex(of: "--ui-test-suite"), let defaults = UserDefaults(suiteName: CommandLine.arguments[index + 1]) {
                store.liveBrowser.sourceSort = .original
                guard LiveBrowserState(defaults: defaults).sourceSort == .original else { store.shutdown(); exit(1) }
                store.liveBrowser.sourceSort = .latency
            }
            let sources = SourcesView(probe: model, browser: store.liveBrowser).environmentObject(store).preferredColorScheme(.dark).tint(Theme.accent)
                .frame(width: 960, height: 1100).background(Theme.background)
            let hosting = NSHostingView(rootView: sources)
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 960, height: 1100), styleMask: .borderless, backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false; window.contentView = hosting
            try await Task.sleep(nanoseconds: 250_000_000); hosting.layoutSubtreeIfNeeded()
            guard !window.isVisible, let bitmap = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else { store.shutdown(); exit(1) }
            hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
            let output = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".build/source-latency-preview.png")
            guard let data = bitmap.representation(using: .png, properties: [:]) else { store.shutdown(); exit(1) }
            try data.write(to: output); print("Rendered offscreen source latency: \(output.path)")
            window.close()
            store.shutdown()
        } catch { print("Render failed: \((error as NSError).domain) (\((error as NSError).code))"); exit(1) }
    }
}
