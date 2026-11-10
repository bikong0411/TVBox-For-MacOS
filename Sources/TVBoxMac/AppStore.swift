import SwiftUI
import AppKit
import AVKit
import TVBoxCore
import UniformTypeIdentifiers

enum Section: String, CaseIterable, Identifiable {
    case discover = "发现", live = "电视直播", favorites = "我的收藏", history = "播放记录", sources = "配置管理", network = "网络探测"
    var id: String { rawValue }
    var icon: String {
        switch self { case .discover: return "square.grid.2x2"; case .live: return "tv"; case .favorites: return "heart"; case .history: return "clock.arrow.circlepath"; case .sources: return "slider.horizontal.3"; case .network: return "network" }
    }
}

struct DetailSelection: Identifiable {
    var video: Video
    var site: Site?
    var resume: LibraryEntry?
    var id: String { (site?.key ?? "demo") + video.id }
}

struct Playback {
    var video: Video
    var site: Site?
    var line: PlayLine
    var index: Int
    var headers: [String: String]
    var isLive: Bool = false
    var catchupProgramme: Programme?
    var episode: Episode { line.episodes[index] }
}

enum LiveSourceSort: String, CaseIterable, Identifiable {
    case latency, original
    var id: String { rawValue }
    var title: String { self == .latency ? "时延从低到高" : "原始顺序" }
}

enum LiveLayout: String, CaseIterable, Identifiable {
    case list, grid
    var id: String { rawValue }
    var title: String { self == .list ? "列表" : "平铺" }
    var icon: String { self == .list ? "list.bullet" : "square.grid.2x2" }
}

@MainActor final class LiveBrowserState: ObservableObject {
    @Published var group = "全部"
    @Published var query = ""
    @Published var grouping: ChannelGrouping {
        didSet {
            if oldValue != grouping { group = "全部"; defaults.set(grouping.rawValue, forKey: "live.channel-grouping.v1") }
        }
    }
    @Published var layout: LiveLayout {
        didSet { if oldValue != layout { defaults.set(layout.rawValue, forKey: "live.layout.v1") } }
    }
    @Published var sourceSort: LiveSourceSort {
        didSet { if oldValue != sourceSort { defaults.set(sourceSort.rawValue, forKey: "live.source-sort.v1") } }
    }
    private let defaults: UserDefaults
    var lastChannelID: String?
    init(defaults: UserDefaults) {
        self.defaults = defaults
        grouping = ChannelGrouping(rawValue: defaults.string(forKey: "live.channel-grouping.v1") ?? "") ?? .automatic
        layout = LiveLayout(rawValue: defaults.string(forKey: "live.layout.v1") ?? "") ?? .grid
        sourceSort = LiveSourceSort(rawValue: defaults.string(forKey: "live.source-sort.v1") ?? "") ?? .latency
    }
    func reset() { group = "全部"; query = ""; lastChannelID = nil }
}

@MainActor final class PlayerController: ObservableObject {
    let player = AVPlayer()
    private var storedVideoSurface: PersistentVideoSurface?
    var videoSurface: PersistentVideoSurface {
        if let storedVideoSurface { return storedVideoSurface }
        let surface = PersistentVideoSurface(player: player); storedVideoSurface = surface; return surface
    }
    func stopPresentation() { storedVideoSurface?.stopPictureInPicture() }
    @Published var error: String?
    @Published var failure: PlaybackFailure?
    @Published var ready = false
    @Published var rate: Float = 1
    @Published var usingCompatibility = false
    @Published var connectingMessage = "正在连接视频…"
    var onProgress: ((Double) -> Void)?
    var onEnd: (() -> Void)?
    var onReady: (() -> Void)?
    private var status: NSKeyValueObservation?
    private var timeToken: Any?
    private var endToken: NSObjectProtocol?
    private var failToken: NSObjectProtocol?
    private var generation = UUID()
    private var compatibilityTask: Task<Void, Never>?
    private var compatibilityMonitor: Task<Void, Never>?
    private var remuxSession: LiveRemuxSession?
    private var compatibilityAttempted = false
    private var connectionTimeout: Task<Void, Never>?
    private var livePlan: LiveRoutePlan?
    private var liveHeaders: [String: String] = [:]
    private var onLiveRoute: ((Int) -> Void)?
    private struct PlaybackRequest {
        let episode: Episode
        let headers: [String: String]
        let position: Double
        let isLive: Bool
    }
    private var currentRequest: PlaybackRequest?
    private var tlsRetryAttempted = false
    private var tlsRetryTask: Task<Void, Never>?
    private var pendingKeyboardSeek: Double?
    private var keyboardSeekGeneration = UUID()
    init() {
        player.allowsExternalPlayback = true
        timeToken = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 5, preferredTimescale: 600), queue: .main) { [weak self] time in
            Task { @MainActor in if time.seconds.isFinite { self?.onProgress?(time.seconds) } }
        }
    }
    func play(_ episode: Episode, headers: [String: String], position: Double = 0, isLive: Bool = false) {
        stop(); error = nil; failure = nil; ready = false
        begin(episode, headers: headers, position: position, isLive: isLive)
    }
    func playLive(_ episodes: [Episode], index: Int, headers: [String: String], onRoute: @escaping (Int) -> Void) {
        stop(); error = nil; failure = nil
        livePlan = LiveRoutePlan(episodes: episodes, startingAt: index)
        liveHeaders = headers; onLiveRoute = onRoute
        if let next = livePlan?.next() { startLiveRoute(next) }
        else { finishFailure(PlaybackFailure(error: URLError(.badURL))) }
    }
    private func startLiveRoute(_ index: Int) {
        guard let plan = livePlan else { return }
        clearAttempt(); error = nil; failure = nil
        onLiveRoute?(index)
        begin(plan.episodes[index], headers: liveHeaders, isLive: true)
    }
    private func connectionText(_ text: String) -> String {
        guard let plan = livePlan, let index = plan.currentIndex else { return text }
        return "线路 \(index + 1)/\(plan.episodes.count) · " + text
    }
    private func begin(_ episode: Episode, headers: [String: String], position: Double = 0, isLive: Bool, retryingTLS: Bool = false, resumePaused: Bool = false) {
        currentRequest = PlaybackRequest(episode: episode, headers: headers, position: position, isLive: isLive)
        tlsRetryAttempted = retryingTLS
        guard let url = URL(string: episode.url), ["http", "https", "file"].contains(url.scheme?.lowercased() ?? "") else {
            finishFailure(PlaybackFailure(error: URLError(.unsupportedURL))); return
        }
        let token = UUID(); generation = token
        connectingMessage = connectionText("正在连接视频…")
        if isLive && url.pathExtension.lowercased() == "flv" {
            startCompatibility(episode, headers: headers, token: token); return
        }
        loadAsset(url, headers: headers, position: position, token: token, fallback: isLive ? episode : nil, resumePaused: resumePaused)
    }
    private func loadAsset(_ url: URL, headers: [String: String], position: Double, token: UUID, fallback: Episode?, resumePaused: Bool = false) {
        connectionTimeout?.cancel()
        if livePlan != nil {
            connectionTimeout = Task { [weak self] in
                do { try await Task.sleep(nanoseconds: 15_000_000_000) } catch { return }
                guard let self, self.generation == token, !self.ready else { return }
                self.finishFailure(PlaybackFailure(error: URLError(.timedOut)))
            }
        }
        let asset = AVURLAsset(url: url, options: headers.isEmpty ? nil : ["AVURLAssetHTTPHeaderFieldsKey": headers])
        let item = AVPlayerItem(asset: asset)
        if usingCompatibility { item.preferredForwardBufferDuration = 3 }
        status = item.observe(\.status, options: [.new, .initial]) { [weak self] item, _ in
            Task { @MainActor in
                guard let self, self.generation == token else { return }
                if item.status == .failed { self.handleFailure(item.error, item: item, fallback: fallback, headers: headers) }
                if item.status == .readyToPlay {
                    self.connectionTimeout?.cancel(); self.connectionTimeout = nil
                    self.ready = true
                    if position.isFinite && position > 0 { self.player.seek(to: CMTime(seconds: position, preferredTimescale: 600)) }
                    if resumePaused { self.player.pause() } else { self.player.playImmediately(atRate: self.rate) }
                    self.onReady?()
                }
            }
        }
        endToken = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main) { [weak self] _ in Task { @MainActor in guard let self, self.generation == token else { return }; self.onEnd?() } }
        failToken = NotificationCenter.default.addObserver(forName: .AVPlayerItemFailedToPlayToEndTime, object: item, queue: .main) { [weak self] notification in
            let error = notification.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? Error
            Task { @MainActor in
                guard let self, self.generation == token else { return }
                self.handleFailure(error, item: item, fallback: fallback, headers: headers)
            }
        }
        player.replaceCurrentItem(with: item)
        if resumePaused { player.pause() } else { player.play() }
    }
    func handleFailure(_ error: Error?, item: AVPlayerItem, fallback: Episode?, headers: [String: String]) {
        // Both status KVO and end-failure notifications can report the same
        // failure. Detached items must never schedule another retry or route.
        guard player.currentItem === item else { return }
        let failure = PlaybackFailure(error: error, mediaStatusCodes: item.errorLog()?.events.map(\.errorStatusCode) ?? [])
        if failure.kind == .tls, !tlsRetryAttempted, !usingCompatibility, let request = currentRequest {
            let position = livePlan != nil ? 0 : (ready && player.currentTime().seconds.isFinite ? max(0, player.currentTime().seconds) : request.position)
            let paused = ready && player.rate == 0
            clearAttempt()
            tlsRetryAttempted = true
            connectingMessage = connectionText("连接未成功，正在自动重试（1/1）…")
            let token = generation
            tlsRetryTask = Task { [weak self] in
                do { try await Task.sleep(nanoseconds: 700_000_000) } catch { return }
                guard let self, self.generation == token else { return }
                self.tlsRetryTask = nil
                self.begin(request.episode, headers: request.headers, position: position, isLive: request.isLive, retryingTLS: true, resumePaused: paused)
            }
            return
        }
        let nsError = error as NSError?
        let canRemux = nsError?.domain == AVFoundationErrorDomain && [AVError.serverIncorrectlyConfigured.rawValue, AVError.fileFormatNotRecognized.rawValue].contains(nsError?.code ?? 0)
        if let fallback, !compatibilityAttempted, canRemux {
            startCompatibility(fallback, headers: headers, token: generation)
        } else { finishFailure(failure) }
    }
    private func startCompatibility(_ episode: Episode, headers: [String: String], token: UUID) {
        guard generation == token, !compatibilityAttempted, let input = URL(string: episode.url) else { return }
        compatibilityAttempted = true; usingCompatibility = true; ready = false; error = nil; failure = nil
        connectingMessage = connectionText("正在启动直播兼容播放，请稍候…")
        let compatibilityToken = UUID(); generation = compatibilityToken
        connectionTimeout?.cancel(); connectionTimeout = nil
        if livePlan != nil {
            connectionTimeout = Task { [weak self] in
                do { try await Task.sleep(nanoseconds: 20_000_000_000) } catch { return }
                guard let self, self.generation == compatibilityToken, !self.ready else { return }
                self.finishFailure(PlaybackFailure(error: LiveRemuxFailure(timeout: true)))
            }
        }
        clearAsset(); player.pause(); player.replaceCurrentItem(with: nil)
        compatibilityTask = Task {
            do {
                let session = try LiveRemuxSession(helperURL: LiveRemuxSession.bundledHelperURL)
                remuxSession = session
                let url = try await session.start(input: input, headers: headers)
                guard !Task.isCancelled, generation == compatibilityToken else { session.stop(); return }
                connectingMessage = connectionText("正在缓冲直播…")
                loadAsset(url, headers: [:], position: 0, token: compatibilityToken, fallback: nil)
                compatibilityMonitor = Task {
                    while !Task.isCancelled && generation == compatibilityToken {
                        if let helperError = session.exitErrorIfFailed() {
                            self.finishFailure(PlaybackFailure(error: helperError)); break
                        }
                        do { try await Task.sleep(nanoseconds: 1_000_000_000) } catch { break }
                    }
                }
            } catch {
                guard !Task.isCancelled, generation == compatibilityToken else { return }
                finishFailure(PlaybackFailure(error: error))
            }
        }
    }
    private func finishFailure(_ failure: PlaybackFailure) {
        if let next = livePlan?.next() {
            clearAttempt(); let token = generation
            Task { [weak self] in
                guard let self, self.generation == token else { return }
                self.startLiveRoute(next)
            }
            return
        }
        let count = livePlan?.attemptedCount ?? 0
        let retryMessage = tlsRetryAttempted ? "已自动重试 1 次，仍未能播放。\n" : ""
        clearAttempt()
        self.failure = failure
        self.error = (count > 1 ? "已尝试 \(count) 条线路，均未成功。\n" : "") + retryMessage + failure.message
    }
    private func clearAsset() {
        status = nil
        if let endToken { NotificationCenter.default.removeObserver(endToken) }; endToken = nil
        if let failToken { NotificationCenter.default.removeObserver(failToken) }; failToken = nil
    }
    func stop() {
        livePlan = nil; liveHeaders = [:]; onLiveRoute = nil
        clearAttempt()
    }
    private func clearAttempt() {
        pendingKeyboardSeek = nil; keyboardSeekGeneration = UUID()
        generation = UUID(); compatibilityTask?.cancel(); compatibilityTask = nil
        tlsRetryTask?.cancel(); tlsRetryTask = nil; currentRequest = nil; tlsRetryAttempted = false
        compatibilityMonitor?.cancel(); compatibilityMonitor = nil
        connectionTimeout?.cancel(); connectionTimeout = nil
        remuxSession?.stop(); remuxSession = nil
        compatibilityAttempted = false; usingCompatibility = false
        player.pause(); clearAsset()
        player.replaceCurrentItem(with: nil); ready = false
    }
    func setRate(_ value: Float) { rate = value; if player.rate != 0 { player.rate = value } }
    @discardableResult func seekRelative(by seconds: Double) -> Bool {
        guard ready, livePlan == nil, seconds.isFinite, let item = player.currentItem else { return false }
        let duration = item.duration.seconds, position = player.currentTime().seconds
        guard duration.isFinite, duration > 0, position.isFinite else { return false }
        let target = min(max(0, (pendingKeyboardSeek ?? position) + seconds), duration)
        pendingKeyboardSeek = target
        let token = UUID(); keyboardSeekGeneration = token
        player.seek(to: CMTime(seconds: target, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero) { [weak self, weak item] _ in
            Task { @MainActor in
                guard let self, self.keyboardSeekGeneration == token, self.player.currentItem === item else { return }
                self.pendingKeyboardSeek = nil
            }
        }
        return true
    }
    deinit {
        if let timeToken { player.removeTimeObserver(timeToken) }
        if let endToken { NotificationCenter.default.removeObserver(endToken) }
        if let failToken { NotificationCenter.default.removeObserver(failToken) }
    }
}

@MainActor final class AppStore: ObservableObject {
    @Published var section: Section = .discover
    @Published private(set) var sourceLibrary = SourceLibrary()
    @Published var siteID = ""
    @Published var category = ""
    @Published var categories: [TVBoxCore.Category] = []
    @Published var videos: [Video] = []
    @Published var query = ""
    @Published var submittedQuery = ""
    @Published var page = 1
    @Published var pageCount = 1
    @Published var loading = false
    @Published var catalogError: String?
    @Published var alert: String?
    @Published var importSheet = false
    @Published var directSheet = false
    @Published var importing = false
    @Published var importError: String?
    @Published var importNotice: String?
    @Published var importTarget: SourceImportTarget = .automatic
    @Published var refreshingSources = Set<String>()
    @Published var detail: DetailSelection?
    @Published var favorites: [LibraryEntry] = []
    @Published var history: [LibraryEntry] = []
    @Published private(set) var channelIndex = ChannelIndex(channels: [])
    @Published private(set) var channelRevision = 0
    @Published var liveLoading = false
    @Published var liveError: String?
    @Published var playback: Playback?
    let player = PlayerController()
    let fullscreen: PlaybackFullscreenPresenter
    let service = TVService()
    let liveBrowser: LiveBrowserState
    let networkProbe = NetworkProbeModel()
    private var catalogTask: Task<Void, Never>?
    private var liveTask: Task<Void, Never>?
    private var requestID = UUID()
    private var liveRequestID = UUID()
    private var lastSave = Date.distantPast
    private let defaults: UserDefaults
    private let preferenceWriter: PreferenceWriter
    private var channelCache: [String: (date: Date, index: ChannelIndex)] = [:]
    private var cacheOrder: [String] = []
    private var liveNavigation: [Channel] = []
    private var liveNavigationSource: String?
    private var workingLiveRoutes: [String: String] = [:]
    var channels: [Channel] { channelIndex.channels }
    var configuration: Configuration? { sourceLibrary.activeVOD?.configuration }
    var vodSources: [SavedVODSource] { sourceLibrary.vodSources }
    var liveSources: [SavedLiveSource] { sourceLibrary.liveSources }
    var selectedVODSource: SavedVODSource? { sourceLibrary.activeVOD }
    var selectedLiveSource: SavedLiveSource? { sourceLibrary.activeLive }
    var isDemo: Bool { sourceLibrary.activeVOD == nil }
    var hasSources: Bool { !vodSources.isEmpty || !liveSources.isEmpty }
    var site: Site? { sourceLibrary.activeVOD?.runtimeSite(siteID) }
    var supportedSites: [Site] { configuration?.sites.filter(\.supported) ?? [] }
    init(fullscreen: PlaybackFullscreenPresenter? = nil) {
        self.fullscreen = fullscreen ?? PlaybackFullscreenPresenter()
        // The normal application domain is selected by .standard. Passing the
        // bundle identifier as a suite name can return nil in a packaged app.
        if ProcessInfo.processInfo.arguments.contains("--ui-test") {
            let arguments = ProcessInfo.processInfo.arguments
            let index = arguments.firstIndex(of: "--ui-test-suite")
            let suite = index.flatMap { arguments.indices.contains($0 + 1) ? arguments[$0 + 1] : nil } ?? "local.tvboxmac.ui-test"
            defaults = UserDefaults(suiteName: suite) ?? .standard
        } else {
            defaults = .standard
        }
        liveBrowser = LiveBrowserState(defaults: defaults)
        preferenceWriter = PreferenceWriter(defaults: defaults)
        var needsLibrarySave = false
        if let saved = read(SourceLibrary.self, key: "sourceLibrary.v1") {
            sourceLibrary = saved; sourceLibrary.normalizeSelections()
            needsLibrarySave = sourceLibrary.compactPayloads()
        } else {
            sourceLibrary = SourceLibrary.migrating(read(Configuration.self, key: "configuration"), siteID: defaults.string(forKey: "siteID") ?? "")
            needsLibrarySave = true
        }
        if let selection = read(SourceSelection.self, key: "sourceSelection.v1") { sourceLibrary.restoreSelection(selection) }
        favorites = read([LibraryEntry].self, key: "favorites") ?? []
        history = read([LibraryEntry].self, key: "history") ?? []
        if let legacy = read(Configuration.self, key: "configuration") {
            favorites = sourceLibrary.scopeLegacyEntries(favorites, legacyLocation: legacy.location)
            history = sourceLibrary.scopeLegacyEntries(history, legacyLocation: legacy.location)
            save(favorites, key: "favorites"); save(history, key: "history")
        }
        siteID = sourceLibrary.activeVOD?.selectedSiteID ?? ""
        player.onProgress = { [weak self] in self?.saveProgress($0) }
        player.onEnd = { [weak self] in self?.nextEpisode() }
        player.onReady = { [weak self] in
            guard let self, let current = self.playback, current.isLive, current.catchupProgramme == nil else { return }
            self.workingLiveRoutes[current.video.id] = current.episode.url
        }
        if needsLibrarySave { persistLibrary() }
        refresh(); refreshLive()
    }
    private func read<T: Decodable>(_ type: T.Type, key: String) -> T? {
        guard let data = defaults.data(forKey: key) else { return nil }; return try? JSONDecoder().decode(type, from: data)
    }
    private func save<T: Encodable & Sendable>(_ value: T, key: String) { preferenceWriter.save(value, key: key) }
    private func persistLibrary() { save(sourceLibrary, key: "sourceLibrary.v1"); persistSelection() }
    private func persistSelection() { save(sourceLibrary.selection, key: "sourceSelection.v1") }
    func refresh(append: Bool = false) {
        catalogTask?.cancel(); requestID = UUID(); let token = requestID
        catalogError = nil
        if !append { page = 1; videos = []; categories = [] }
        if isDemo {
            videos = Demo.videos.filter { submittedQuery.isEmpty || $0.title.localizedCaseInsensitiveContains(submittedQuery) }; loading = false; pageCount = 1; return
        }
        guard let site else { loading = false; return }
        loading = true
        let selectedCategory = category; let search = submittedQuery; let targetPage = append ? page + 1 : 1
        catalogTask = Task {
            do {
                async let categoryResult = try? service.categories(site: site)
                let result = try await service.catalog(site: site, category: selectedCategory, search: search, page: targetPage)
                let fetchedCategories = await categoryResult
                guard !Task.isCancelled, requestID == token else { return }
                categories = fetchedCategories ?? result.categories
                if append { var ids = Set(videos.map(\.id)); videos += result.videos.filter { ids.insert($0.id).inserted } } else { videos = result.videos }
                page = targetPage; pageCount = result.pageCount; loading = false
            } catch {
                guard !Task.isCancelled, requestID == token else { return }
                catalogError = error.localizedDescription; loading = false
            }
        }
    }
    func selectSite(_ id: String) {
        guard id != siteID else { return }
        sourceLibrary.selectSite(id); siteID = sourceLibrary.activeVOD?.selectedSiteID ?? ""
        persistSelection(); category = ""; query = ""; submittedQuery = ""; refresh()
    }
    func selectVODSource(_ id: String) {
        guard id != sourceLibrary.selectedVODID else { return }
        guard sourceLibrary.selectVOD(id) else { return }
        if playback?.isLive == false { stop() }
        siteID = sourceLibrary.activeVOD?.selectedSiteID ?? ""; category = ""; query = ""; submittedQuery = ""
        persistSelection(); refresh()
    }
    func selectLiveSource(_ id: String) {
        guard id != sourceLibrary.selectedLiveID else { return }
        guard sourceLibrary.selectLive(id) else { return }
        if playback?.isLive == true { stop() }
        liveBrowser.reset(); liveNavigation = []
        persistSelection(); refreshLive(force: false)
    }
    func showImport(_ target: SourceImportTarget = .automatic) { importTarget = target; importError = nil; importSheet = true }
    func search() { submittedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines); category = ""; refresh() }
    func selectCategory(_ id: String) { category = id; refresh() }
    func importURL(_ text: String, target: SourceImportTarget = .automatic, name: String = "") async {
        guard let url = URL(string: text.trimmingCharacters(in: .whitespacesAndNewlines)), ["http", "https", "file"].contains(url.scheme?.lowercased() ?? "") else { importError = "请输入完整的 http:// 或 https:// 配置地址。"; return }
        importing = true; importError = nil
        do { let config = try await service.configuration(at: url); try apply(config, target: target, name: name); importSheet = false }
        catch { importError = error.localizedDescription }
        importing = false
    }
    func importFile(target: SourceImportTarget = .automatic, name: String = "") {
        let panel = NSOpenPanel(); panel.title = "导入 TVBox 配置或直播列表"; panel.allowedContentTypes = [.json, .plainText, UTType(filenameExtension: "m3u") ?? .text, UTType(filenameExtension: "m3u8") ?? .text]; panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await importURL(url.absoluteString, target: target, name: name); if let importError { alert = importError } }
    }
    func apply(_ config: Configuration, target: SourceImportTarget = .automatic, name: String = "") throws {
        let previousVODID = sourceLibrary.selectedVODID
        let result = try sourceLibrary.add(config, target: target, name: name)
        persistLibrary()
        if result.updatedVOD {
            if playback?.isLive == false { stop() }
            siteID = sourceLibrary.activeVOD?.selectedSiteID ?? ""; category = ""; query = ""; submittedQuery = ""; refresh()
        }
        if result.updatedLive {
            if playback?.isLive == true { stop() }
            channelCache.removeAll(); cacheOrder.removeAll(); liveBrowser.reset(); refreshLive()
        }
        importNotice = nil
        if result.updatedVOD && !config.sites.isEmpty && !config.sites.contains(where: \.supported) {
            let keptExisting = previousVODID != nil && sourceLibrary.selectedVODID == previousVODID && config.location != selectedVODSource?.origin
            importNotice = "配置已保存：\(config.sites.count) 个点播接口均需要爬虫运行时，当前版本暂不能用于点播。" + (keptExisting ? "原点播源保持选中。" : "可在下方查看兼容状态。") + (result.updatedLive ? "另已保存直播来源，可在“电视直播”页选择。" : "")
            section = .sources
        }
        else if target == .live { section = .live }
        else if result.updatedVOD { section = .discover }
        else { section = .live }
    }
    func removeSource(_ id: String, live: Bool) {
        if live {
            let wasActive = sourceLibrary.selectedLiveID == id; sourceLibrary.removeLive(id)
            channelCache.removeValue(forKey: id); cacheOrder.removeAll { $0 == id }
            if wasActive { if playback?.isLive == true { stop() }; liveBrowser.reset(); refreshLive(force: false) }
        } else {
            let wasActive = sourceLibrary.selectedVODID == id; sourceLibrary.removeVOD(id)
            if wasActive {
                if playback?.isLive == false { stop() }
                siteID = sourceLibrary.activeVOD?.selectedSiteID ?? ""; category = ""; query = ""; submittedQuery = ""; refresh()
            }
        }
        persistLibrary()
    }
    func renameSource(_ id: String, name: String, live: Bool) {
        if live { sourceLibrary.renameLive(id, name: name) } else { sourceLibrary.renameVOD(id, name: name) }
        persistLibrary()
    }
    func refreshSource(_ id: String, live: Bool) async {
        let origin = live ? liveSources.first(where: { $0.id == id })?.origin : vodSources.first(where: { $0.id == id })?.origin
        guard let origin, let url = URL(string: origin), ["http", "https", "file"].contains(url.scheme ?? "") else { alert = "此源没有可刷新的配置地址。"; return }
        guard !refreshingSources.contains(id) else { return }; refreshingSources.insert(id)
        defer { refreshingSources.remove(id) }
        do {
            let config = try await service.configuration(at: url)
            // A source removed while its refresh was running must stay removed.
            guard live ? liveSources.contains(where: { $0.id == id }) : vodSources.contains(where: { $0.id == id }) else { return }
            let activeOrigin = live ? selectedLiveSource?.origin : selectedVODSource?.origin
            _ = try sourceLibrary.add(config, target: live ? .live : .vod, activate: false)
            persistLibrary()
            if live {
                let affected = Set(liveSources.filter { $0.origin == origin }.map(\.id))
                channelCache = channelCache.filter { !affected.contains($0.key) }; cacheOrder.removeAll { affected.contains($0) }
            }
            if activeOrigin == origin {
                if live { refreshLive() }
                else { siteID = sourceLibrary.activeVOD?.selectedSiteID ?? ""; category = ""; refresh() }
            }
        } catch { alert = error.localizedDescription }
    }
    private func publishChannels(_ index: ChannelIndex) { channelIndex = index; channelRevision &+= 1 }
    func setLiveNavigation(_ channels: [Channel]) { liveNavigation = channels; liveNavigationSource = sourceLibrary.selectedLiveID }
    func refreshLive(force: Bool = true) {
        liveTask?.cancel(); liveRequestID = UUID(); let token = liveRequestID
        liveError = nil
        guard let source = selectedLiveSource else { publishChannels(ChannelIndex(channels: [])); liveLoading = false; return }
        if !force, let cached = channelCache[source.id], Date().timeIntervalSince(cached.date) < 300 {
            cacheOrder.removeAll { $0 == source.id }; cacheOrder.append(source.id)
            publishChannels(cached.index); liveLoading = false; return
        }
        publishChannels(ChannelIndex(channels: [])); liveLoading = true
        let feeds = source.feeds
        liveTask = Task {
            var failures: [String] = []
            var rawChannels = source.channels
            for feed in feeds {
                do {
                    let list = try await service.channels(feed: feed)
                    guard !Task.isCancelled, liveRequestID == token else { return }
                    rawChannels += list
                } catch { if !Task.isCancelled { failures.append("\(feed.name)：\(error.localizedDescription)") } }
            }
            guard !Task.isCancelled, liveRequestID == token else { return }
            let input = rawChannels
            let index = await Task.detached(priority: .userInitiated) { ChannelIndex(channels: input) }.value
            guard !Task.isCancelled, liveRequestID == token else { return }
            if failures.isEmpty {
                channelCache[source.id] = (Date(), index); cacheOrder.removeAll { $0 == source.id }; cacheOrder.append(source.id)
                while cacheOrder.count > 8 { channelCache.removeValue(forKey: cacheOrder.removeFirst()) }
            }
            publishChannels(index); liveLoading = false; liveError = failures.isEmpty ? nil : failures.joined(separator: "\n")
        }
    }
    func show(_ video: Video, site: Site?, resume: LibraryEntry? = nil) { detail = DetailSelection(video: video, site: site, resume: resume) }
    func isFavorite(_ video: Video, site: Site?) -> Bool { favorites.contains { $0.id == LibraryEntry(video: video, site: site).id } }
    func toggleFavorite(_ video: Video, site: Site?) {
        let item = LibraryEntry(video: video, site: site)
        if favorites.contains(where: { $0.id == item.id }) { favorites.removeAll { $0.id == item.id } } else { favorites.insert(item, at: 0) }
        save(favorites, key: "favorites")
    }
    func clearHistory() { history = []; save(history, key: "history") }
    func play(video: Video, site: Site?, line: PlayLine, index: Int, position: Double = 0, headers: [String: String]? = nil, live: Bool = false) {
        guard line.episodes.indices.contains(index) else { return }
        saveCurrentPosition(); playback = Playback(video: video, site: site, line: line, index: index, headers: headers ?? site?.headers ?? [:], isLive: live)
        detail = nil
        if live {
            player.playLive(line.episodes, index: index, headers: headers ?? site?.headers ?? [:]) { [weak self] route in self?.playback?.index = route }
        } else { player.play(line.episodes[index], headers: headers ?? site?.headers ?? [:], position: position) }
        if !live {
            var item = LibraryEntry(video: video, site: site, episode: line.episodes[index], position: position)
            item.updated = Date(); history.removeAll { $0.id == item.id }; history.insert(item, at: 0); history = Array(history.prefix(100)); save(history, key: "history")
        }
    }
    func playChannel(_ channel: Channel, index: Int? = nil) {
        liveBrowser.lastChannelID = channel.id
        if liveNavigationSource != sourceLibrary.selectedLiveID || !liveNavigation.contains(where: { $0.id == channel.id }) { setLiveNavigation(channels) }
        let line = PlayLine(name: channel.group, episodes: channel.urls.enumerated().map { Episode(name: "线路 \($0.offset + 1)", url: $0.element) })
        let selected = index ?? workingLiveRoutes[channel.id].flatMap { channel.urls.firstIndex(of: $0) } ?? 0
        play(video: Video(id: channel.id, title: channel.name, note: "正在直播"), site: nil, line: line, index: selected, headers: channel.headers, live: true)
    }
    var playingChannel: Channel? { channels.first { $0.id == playback?.video.id } }
    func playCatchup(_ programme: Programme, channel: Channel) {
        guard let url = channel.guide?.catchup?.playbackURL(programme: programme, liveURL: channel.urls.first ?? "") else { return }
        saveCurrentPosition()
        let line = PlayLine(name: "节目回看", episodes: [Episode(name: programme.title, url: url.absoluteString)])
        playback = Playback(video: Video(id: channel.id, title: channel.name, note: "节目回看"), site: nil, line: line, index: 0, headers: channel.headers, isLive: true, catchupProgramme: programme)
        detail = nil
        // A finite catch-up item must not trigger live route retries or history writes.
        player.play(line.episodes[0], headers: channel.headers, isLive: true)
    }
    func retryPlayback() {
        guard let current = playback else { return }
        if let programme = current.catchupProgramme, let channel = playingChannel { playCatchup(programme, channel: channel); return }
        if current.isLive { play(video: current.video, site: current.site, line: current.line, index: current.index, headers: current.headers, live: true) }
        else { player.play(current.episode, headers: current.headers) }
    }
    func nextLiveRoute() {
        guard let current = playback, current.isLive, current.line.episodes.count > 1 else { return }
        play(video: current.video, site: current.site, line: current.line, index: (current.index + 1) % current.line.episodes.count, headers: current.headers, live: true)
    }
    func canSwitchChannel(_ offset: Int) -> Bool {
        guard playback?.isLive == true, let id = playback?.video.id, let index = liveNavigation.firstIndex(where: { $0.id == id }) else { return false }
        return liveNavigation.indices.contains(index + offset)
    }
    func switchChannel(_ offset: Int) {
        guard playback?.isLive == true, let id = playback?.video.id, let index = liveNavigation.firstIndex(where: { $0.id == id }), liveNavigation.indices.contains(index + offset) else { return }
        playChannel(liveNavigation[index + offset])
    }
    func playDirect(_ text: String) -> Bool {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: value), ["http", "https", "file", "rtsp", "rtmp"].contains(url.scheme?.lowercased() ?? "") else { alert = "请输入有效的视频地址。"; return false }
        let video = Video(id: value, title: url.deletingPathExtension().lastPathComponent.isEmpty ? "视频直链" : url.deletingPathExtension().lastPathComponent, lines: [PlayLine(name: "直链", episodes: [Episode(name: "播放", url: value)])])
        play(video: video, site: nil, line: video.lines[0], index: 0); return true
    }
    func openVideoFile() {
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.movie, .video, .audio]; panel.canChooseDirectories = false
        if panel.runModal() == .OK, let url = panel.url { _ = playDirect(url.absoluteString) }
    }
    func nextEpisode() {
        guard let current = playback, !current.isLive, current.index + 1 < current.line.episodes.count else { return }
        play(video: current.video, site: current.site, line: current.line, index: current.index + 1)
    }
    func saveProgress(_ position: Double) {
        guard let current = playback, !current.isLive, position.isFinite, let index = history.firstIndex(where: { $0.id == LibraryEntry(video: current.video, site: current.site).id }) else { return }
        history[index].position = position; history[index].updated = Date()
        if Date().timeIntervalSince(lastSave) > 10 { save(history, key: "history"); lastSave = Date() }
    }
    func saveCurrentPosition() {
        guard let current = playback, !current.isLive else { return }
        let position = player.player.currentTime().seconds; if position.isFinite { saveProgress(position) }; save(history, key: "history")
    }
    func stop() { fullscreen.close(); saveCurrentPosition(); player.stopPresentation(); player.stop(); playback = nil }
    func shutdown() { fullscreen.closeImmediately(); networkProbe.cancel(); saveCurrentPosition(); player.stopPresentation(); player.stop(); preferenceWriter.flush() }
    func openIINA() {
        guard let current = playback, let original = URL(string: current.episode.url) else { return }
        if let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.colliderli.iina") {
            NSWorkspace.shared.open([original], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration()) { _, error in
                if let error { Task { @MainActor in self.alert = error.localizedDescription } }
            }
            player.player.pause()
        } else { alert = "尚未安装 IINA。可以复制播放地址，在其他播放器中打开。" }
    }
    func copyURL() { guard let url = playback?.episode.url else { return }; NSPasteboard.general.clearContents(); NSPasteboard.general.setString(url, forType: .string) }
}
