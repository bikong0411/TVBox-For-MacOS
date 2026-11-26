import AVKit
import SwiftUI
import TVBoxCore
import UIKit

@MainActor private final class TelevisionPlayer: ObservableObject {
    let player = AVPlayer()
    @Published private(set) var item: TVPlaybackItem
    @Published private(set) var connecting = true
    @Published private(set) var failure: String?
    private var route = 0
    private var startupPosition: Double
    private var status: NSKeyValueObservation?
    private var progressObserver: Any?
    private var save: ((TVPlaybackItem, Double) -> Void)?

    init(item: TVPlaybackItem) {
        self.item = item
        startupPosition = item.position
    }

    var position: Double {
        let seconds = player.currentTime().seconds
        return seconds.isFinite && seconds > 0 ? seconds : startupPosition
    }

    func start(save: @escaping (TVPlaybackItem, Double) -> Void) {
        guard progressObserver == nil else { return }
        self.save = save
        progressObserver = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 15, preferredTimescale: 600), queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in self?.savePosition() }
        }
        load()
    }

    func change(to selection: TVPlaybackItem, at seconds: Double) {
        savePosition()
        item = selection
        route = 0
        startupPosition = seconds
        load()
    }

    func retry() {
        route = 0
        load()
    }

    func stop() {
        savePosition()
        player.pause()
        status?.invalidate()
        status = nil
        player.replaceCurrentItem(with: nil)
        if let progressObserver {
            player.removeTimeObserver(progressObserver)
            self.progressObserver = nil
        }
        save = nil
    }

    private func savePosition() {
        guard !connecting, failure == nil, player.currentItem?.status == .readyToPlay else { return }
        save?(item, player.currentTime().seconds)
    }

    private func load() {
        status?.invalidate()
        connecting = true
        failure = nil
        let stream = item.streams[route]
        let options = stream.userAgent.map { [AVURLAssetHTTPUserAgentKey: $0] }
        let next = AVPlayerItem(asset: AVURLAsset(url: stream.url, options: options))
        player.replaceCurrentItem(with: next)
        status = next.observe(\.status, options: [.initial, .new]) { [weak self, weak next] _, _ in
            Task { @MainActor [weak self, weak next] in
                guard let self, let next, player.currentItem === next else { return }
                switch next.status {
                case .readyToPlay:
                    connecting = false
                    if startupPosition > 0 {
                        let duration = next.duration.seconds
                        let target = duration.isFinite && startupPosition >= duration - 1 ? 0 : startupPosition
                        player.seek(to: CMTime(seconds: target, preferredTimescale: 600))
                    }
                    player.play()
                case .failed:
                    if route + 1 < item.streams.count { route += 1; load(); return }
                    connecting = false
                    let error = next.error
                    if let error, let failure = PlaybackFailure(error: error).userFacingTVError {
                        self.failure = failure
                    } else {
                        failure = TelevisionError.unsupportedStream.localizedDescription
                    }
                default: break
                }
            }
        }
    }
}

private extension PlaybackFailure {
    var userFacingTVError: String? {
        switch kind {
        case .tls, .certificate: return String(localized: "A secure connection could not be established. Check the stream address or switch sources.")
        default: return nil
        }
    }
}

struct TVPlaybackScreen: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @EnvironmentObject private var store: TelevisionStore
    @StateObject private var session: TelevisionPlayer
    @State private var showSwitch = false

    init(item: TVPlaybackItem) {
        _session = StateObject(wrappedValue: TelevisionPlayer(item: item))
    }

    var body: some View {
        ZStack {
            TVNativePlayer(player: session.player, title: session.item.title,
                           canSwitch: session.item.hit != nil, switchSource: { showSwitch = true }, close: { dismiss() })
                .ignoresSafeArea()
            if session.connecting { ProgressView("Connecting…").padding(24).background(.regularMaterial).allowsHitTesting(false) }
            if let failure = session.failure {
                VStack(spacing: 30) {
                    Text(failure).multilineTextAlignment(.center)
                    HStack {
                        Button("Retry") { session.retry() }
                        if session.item.hit != nil { Button("Switch source") { showSwitch = true } }
                        Button("Close") { dismiss() }
                    }
                }.padding(48).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20))
            }
        }
        .onAppear { session.start { item, seconds in store.saveProgress(item, at: seconds) } }
        .onDisappear { session.stop() }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { store.saveProgress(session.item, at: session.position) }
        }
        .sheet(isPresented: $showSwitch) {
            if let hit = session.item.hit, let line = session.item.line, let episode = session.item.episode {
                NavigationStack {
                    TVSourceSwitch(hit: hit, line: line, episode: episode) { item in
                        session.change(to: item, at: session.position)
                        showSwitch = false
                    }
                }.environmentObject(store)
            }
        }
    }
}

private struct TVNativePlayer: UIViewControllerRepresentable {
    let player: AVPlayer
    let title: String
    let canSwitch: Bool
    let switchSource: () -> Void
    let close: () -> Void

    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let controller = AVPlayerViewController()
        controller.player = player
        return controller
    }

    func updateUIViewController(_ controller: AVPlayerViewController, context: Context) {
        // Rebuild transport actions only when playback metadata changes, so
        // SwiftUI progress updates do not reset the remote's current focus.
        if controller.title == title && context.coordinator.canSwitch == canSwitch { return }
        controller.title = title
        context.coordinator.canSwitch = canSwitch
        var items: [UIAction] = []
        if canSwitch {
            items.append(UIAction(title: String(localized: "Switch source"), image: UIImage(systemName: "arrow.left.arrow.right")) { _ in switchSource() })
        }
        items.append(UIAction(title: String(localized: "Close"), image: UIImage(systemName: "xmark")) { _ in close() })
        controller.transportBarCustomMenuItems = items
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        var canSwitch: Bool?
    }
}

private struct TVSourceSwitch: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var store: TelevisionStore
    let hit: VODSearchHit
    let line: PlayLine
    let episode: Episode
    let onSelection: (TVPlaybackItem) -> Void
    @State private var results = VODPlaybackSearchCache.Results()
    @State private var searching = true
    @State private var initialized = false
    @State private var failure: String?

    private var target: VODPlaybackSearch {
        VODPlaybackSearch(video: hit.video, episode: episode, singleEpisode: line.episodes.count == 1)
    }

    private var cacheKey: VODPlaybackSearchCache.Key { .init(siteID: hit.source.id, search: target) }

    private var sources: [VODSearchSource] {
        VODSearchSource.playbackAlternatives(in: store.vodSources.filter { $0.site.searchable }, excluding: hit.source.site)
    }

    var body: some View {
        List {
            if searching {
                ProgressView("Checking \(results.checked.count) of \(sources.count) sources",
                             value: Double(results.checked.count), total: Double(max(1, sources.count)))
            }
            if let failure { Text(failure).foregroundStyle(.secondary) }
            let matches = options()
            if matches.isEmpty && !searching { Text("No other playable source found.") }
            ForEach(matches) { option in
                Button(option.source.site.name) { select(option) }
            }
            if !searching && !matches.isEmpty && results.checked.count < sources.count {
                Button("More sources") { searching = true; failure = nil }
            }
            Button("Close") { dismiss() }
        }
        .navigationTitle("Switch source")
        .task(id: searching) {
            guard searching else { return }
            let scope = sources
            if !initialized {
                initialized = true
                if let cached = store.switchCache.results(for: cacheKey) { results = cached.retaining(scope) }
                if !options().isEmpty { searching = false; return }
            }
            let remaining = scope.filter { results.checked[$0.id] == nil }
            let page = results.pages.count
            await store.service.searchPlaybackSources(remaining, for: target, availability: store.availability,
                                                       hasResults: { !options(after: page).isEmpty }) { source, hits in
                results.checked[source.id] = source.site
                let supported = hits.filter { candidate in
                    guard let (line, index) = VODMatch.matchingEpisode(episode, in: candidate.video, singleEpisode: target.singleEpisode) else { return false }
                    return (try? TVPlaybackItem.onDemand(candidate, title: candidate.video.title, line: line, episode: line.episodes[index])) != nil
                }
                if !supported.isEmpty {
                    if results.pages.count == page { results.pages.append(supported) }
                    else { results.pages[page] += supported }
                }
                store.switchCache.save(results, for: cacheKey)
            }
            if !Task.isCancelled { searching = false }
        }
    }

    private func options(after page: Int = 0) -> [VODSearchHit] {
        results.pages.dropFirst(page).flatMap { candidates in
            VODMatch.topPlaybackSources(for: hit.video, episode: episode, singleEpisode: target.singleEpisode, from: candidates)
        }
    }

    private func select(_ option: VODSearchHit) {
        do {
            guard let (match, index) = VODMatch.matchingEpisode(episode, in: option.video, singleEpisode: target.singleEpisode) else {
                throw TelevisionError.noEpisode
            }
            onSelection(try TVPlaybackItem.onDemand(option, title: option.video.title, line: match, episode: match.episodes[index]))
        } catch { failure = error.localizedDescription }
    }
}
