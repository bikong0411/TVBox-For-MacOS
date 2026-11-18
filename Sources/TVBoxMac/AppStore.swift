import SwiftUI
import AppKit
import AVKit
import VLCKit
import TVBoxCore
import UniformTypeIdentifiers

enum Section: String, CaseIterable, Identifiable {
    case discover = "发现", live = "电视直播", favorites = "我的收藏", history = "播放记录", sources = "配置管理", network = "网络探测"
    var id: String { rawValue }
    var title: String { L10n.string(rawValue) }
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
    var resolvedEpisode: Episode? = nil
    var cspLease: CSPPlaybackLease? = nil
    var episode: Episode { line.episodes[index] }
}

enum LiveSourceSort: String, CaseIterable, Identifiable {
    case latency, original
    var id: String { rawValue }
    var title: String { L10n.string(self == .latency ? "时延从低到高" : "原始顺序") }
}

enum LiveLayout: String, CaseIterable, Identifiable {
    case list, grid
    var id: String { rawValue }
    var title: String { L10n.string(self == .list ? "列表" : "平铺") }
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
    // The system player is reserved for AirPlay / PiP and custom HTTP headers.
    // Ordinary playback uses the independent VLC framework bundled in the app.
    let player = AVPlayer()
    let dlna = DLNACastingController()
    private(set) var nativeSession: VLCPlaybackSession?
    private(set) var mpvSession: MPVPlaybackSession?
    var preferMPV = false
    @Published private(set) var componentNotice: String?
    var playbackEngine: String { L10n.string(systemPlayback ? "系统播放" : mpvSession != nil ? "IINA 组件 · mpv" : "内置 VLC") }
    private var castTask: Task<Void, Never>?
    private var pendingCastDevice: DLNADevice?
    @Published private(set) var systemPlayback = false
    private var nativeVolume: Double = 1
    private var nativeMuted = false
    private var clockTask: Task<Void, Never>?
    private var nativeSeekTask: Task<Void, Never>?
    private var pendingPiP = false
    @Published private(set) var airPlayPreparing = false
    @Published private(set) var airPlayConnected = false
    @Published private(set) var airPlayMessage: String?
    @Published private(set) var airPlayDiagnostic: String?
    private var airPlayToken = UUID()
    private var airPlayItemObservation: NSKeyValueObservation?
    private var airPlayTimeout: Task<Void, Never>?
    private var airPlayCandidate: AVPlayerItem?
    private var airPlayRouteSelected = false
    private var airPlayStarting = false
    private var airPlaySeekStarted = false
    private var airPlaySeekCompleted = false
    private var airPlayResumePosition: Double = 0
    private var airPlayResumePaused = false
    private var airPlaySeekTimeout: Task<Void, Never>?
    private var airPlayFailureObserver: NSObjectProtocol?
    private let airPlayStartTimeout: TimeInterval
    private var routeObservation: NSKeyValueObservation?
    var position: Double { if dlna.connected { return dlna.state.position }; return systemPlayback ? max(0, player.currentTime().seconds.isFinite ? player.currentTime().seconds : 0) : (mpvSession?.position ?? nativeSession?.position ?? 0) }
    var duration: Double { if dlna.connected { return dlna.state.duration }; let value = systemPlayback ? (player.currentItem?.duration.seconds ?? 0) : (mpvSession?.duration ?? nativeSession?.duration ?? 0); return value.isFinite && value > 0 ? value : 0 }
    var playing: Bool { dlna.connected ? dlna.state.playing : systemPlayback ? player.rate != 0 : (mpvSession?.playing ?? nativeSession?.playing ?? false) }
    var volume: Double { dlna.connected ? (dlna.state.volume ?? 0) : systemPlayback ? Double(player.volume) : nativeVolume }
    var muted: Bool { dlna.connected ? (dlna.state.muted ?? false) : systemPlayback ? player.isMuted : nativeMuted }
    var effectiveRate: Float { dlna.connected ? 1 : (systemPlayback ? rate : mpvSession?.effectiveRate ?? nativeSession?.effectiveRate ?? rate) }
    var canSeek: Bool {
        guard ready, !dlna.connecting, currentRequest?.isLive != true, duration > 0 else { return false }
        return dlna.connected ? dlna.state.canSeek : systemPlayback ? true : (mpvSession?.seekable ?? nativeSession?.seekable ?? false)
    }
    var canPause: Bool { !dlna.connected || !dlna.state.playing || dlna.state.canPause }
    var canVolume: Bool { !dlna.connected || dlna.state.canVolume }
    var canMute: Bool { !dlna.connected || dlna.state.canMute }
    var canUseVLCPlayback: Bool {
        if preferMPV { return true }
        return currentRequest?.headers.keys.allSatisfy { ["user-agent", "referer", "referrer"].contains($0.lowercased()) } ?? true
    }
    func setVolume(_ value: Double) { guard value.isFinite else { return }; if dlna.connected { dlna.setVolume(value); return }; nativeVolume = min(1, max(0, value)); player.volume = Float(nativeVolume); nativeSession?.setVolume(nativeVolume); mpvSession?.setVolume(nativeVolume) }
    func toggleMute() { if dlna.connected { dlna.toggleMute(); return }; nativeMuted = !muted; player.isMuted = nativeMuted; nativeSession?.setMuted(nativeMuted); mpvSession?.setMuted(nativeMuted) }
    func pause() { buffering = false; if dlna.connected { dlna.pause() } else if systemPlayback { airPlayResumePaused = true; player.pause() } else { nativeSession?.pause(); mpvSession?.pause() } }
    func togglePlayback() {
        guard !dlna.connecting else { return }
        if dlna.connected { dlna.togglePlayback(); return }
        if playing { pause() }
        else if systemPlayback { airPlayResumePaused = false; if duration > 0 && position >= duration - 0.1 { seek(to: 0) }; player.playImmediately(atRate: rate) }
        else { if mpvSession?.reachedEnd == true || (duration > 0 && position >= duration - 0.1) { seek(to: 0) }; nativeSession?.play(); mpvSession?.play() }
    }
    func seek(to seconds: Double) {
        guard canSeek, seconds.isFinite else { return }
        nativeSeekTask?.cancel(); pendingKeyboardSeek = nil
        let target = min(max(0, seconds), duration)
        if dlna.connected { dlna.seek(to: target) }
        else if systemPlayback { player.seek(to: CMTime(seconds: target, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero) }
        else { nativeSession?.seek(to: target); mpvSession?.seek(to: target) }
    }
    func useSystemPlayback() {
        if dlna.selectedDevice != nil { returnToLocal(); }
        guard !systemPlayback, let request = currentRequest else { return }
        let resume = position, paused = ready && !playing
        nativeVolume = volume; nativeMuted = muted
        clearAttempt(); systemPlayback = true
        videoSurface.setSystemPlayback(true)
        begin(request.episode, headers: request.headers, position: request.isLive ? 0 : resume, isLive: request.isLive, resumePaused: paused)
    }
    /// Opening the cast popover or changing tabs never calls this method.
    /// Preparing the system route leaves the current decoder and line intact.
    func prepareAirPlayRoute() {
        guard !systemPlayback, ready, let request = currentRequest, airPlayCandidate == nil else { return }
        cancelAirPlayPreparation(); let token = UUID(); airPlayToken = token
        player.allowsExternalPlayback = true
        airPlayPreparing = true; airPlayMessage = "正在准备 AirPlay，当前视频继续播放…"
        guard let url = URL(string: request.episode.url), ["http", "https", "file"].contains(url.scheme ?? "") else {
            airPlayPreparing = false; airPlayMessage = "此片源不支持 AirPlay 直投，可使用 DLNA。"; return
        }
        let item = AVPlayerItem(asset: AVURLAsset(url: url, options: request.headers.isEmpty ? nil : ["AVURLAssetHTTPHeaderFieldsKey": request.headers]))
        airPlayCandidate = item; player.pause(); player.volume = Float(nativeVolume); player.isMuted = nativeMuted
        airPlayItemObservation = item.observe(\.status, options: [.initial, .new]) { [weak self] item, _ in
            Task { @MainActor in
                guard let self, self.airPlayToken == token, self.player.currentItem === item else { return }
                if item.status == .readyToPlay {
                    if !self.airPlayStarting { self.airPlayMessage = "请选择 AirPlay 设备；取消选择不会打断当前播放。" }
                    self.commitAirPlayRouteIfNeeded()
                } else if item.status == .failed {
                    self.failAirPlay("系统播放器无法加载此片源，未完成 AirPlay 投屏。本机继续播放，可尝试“安卓电视 · DLNA”。", error: item.error)
                }
            }
        }
        player.replaceCurrentItem(with: item)
        airPlayFailureObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemFailedToPlayToEndTime, object: item, queue: .main) { [weak self] notification in
            let error = notification.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? Error
            Task { @MainActor in
                guard let self, self.airPlayToken == token else { return }
                self.failAirPlay("AirPlay 播放中断，已返回本机。可尝试“安卓电视 · DLNA”。", error: error)
            }
        }
        airPlayTimeout = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: 30_000_000_000) } catch { return }
            guard let self, self.airPlayToken == token, !self.systemPlayback else { return }
            self.failAirPlay("AirPlay 视频加载超时，未完成投屏。本机继续播放，可尝试“安卓电视 · DLNA”。")
        }
    }
    func cancelAirPlayPreparation() {
        let hadAirPlay = airPlayCandidate != nil || airPlayStarting || airPlayConnected || airPlayRouteSelected
        airPlayToken = UUID(); airPlayTimeout?.cancel(); airPlayTimeout = nil
        airPlaySeekTimeout?.cancel(); airPlaySeekTimeout = nil
        if let observer = airPlayFailureObserver { NotificationCenter.default.removeObserver(observer) }; airPlayFailureObserver = nil
        airPlayItemObservation = nil; airPlayCandidate = nil; airPlayPreparing = false; airPlayMessage = nil; airPlayDiagnostic = nil
        airPlayConnected = false; airPlayStarting = false; airPlayRouteSelected = false
        airPlaySeekStarted = false; airPlaySeekCompleted = false
        if !systemPlayback { player.pause(); if hadAirPlay { player.allowsExternalPlayback = false }; player.replaceCurrentItem(with: nil) }
    }
    /// The system route flag is selection/transport information, not a successful
    /// handoff. Keep the native decoder until the candidate clock really runs.
    func airPlayRouteChanged(_ active: Bool) {
        airPlayRouteSelected = active
        if active {
            if systemPlayback { confirmSystemAirPlayRoute() } else { commitAirPlayRouteIfNeeded() }
        }
        else if airPlayConnected && systemPlayback && (nativeSession != nil || mpvSession != nil) { useVLCPlayback() }
        else if airPlayStarting { failAirPlay("AirPlay 连接已断开，本机继续播放。") }
        else { airPlayConnected = false; if systemPlayback { airPlayPreparing = false; airPlayTimeout?.cancel() } }
    }
    private func confirmSystemAirPlayRoute() {
        guard !airPlayConnected, !airPlayPreparing, let item = player.currentItem else { return }
        airPlayPreparing = true; airPlayMessage = "正在确认 AirPlay 视频输出…"
        airPlayResumePaused = player.rate == 0
        if airPlayResumePaused { player.isMuted = true; player.playImmediately(atRate: rate) }
        let token = airPlayToken, requestToken = generation
        airPlayTimeout?.cancel()
        airPlayTimeout = Task { @MainActor [weak self, weak item] in
            let deadline = Date().addingTimeInterval(self?.airPlayStartTimeout ?? 25)
            var previous: Double?
            while Date() < deadline {
                do { try await Task.sleep(nanoseconds: 100_000_000) } catch { return }
                guard let self, let item, self.airPlayToken == token, self.generation == requestToken,
                      self.airPlayRouteSelected, self.player.currentItem === item else { return }
                let clock = self.player.currentTime().seconds
                if item.status == .readyToPlay, let previous, clock.isFinite, clock > previous + 0.15, self.player.timeControlStatus == .playing {
                    self.airPlayConnected = true; self.airPlayPreparing = false; self.airPlayMessage = nil
                    self.player.isMuted = self.nativeMuted
                    if self.airPlayResumePaused { self.player.pause() }; return
                }
                if previous == nil, clock.isFinite { previous = clock }
            }
            guard let self, self.airPlayToken == token else { return }
            self.failAirPlay("AirPlay 未开始播放，已保留本机播放。可尝试 DLNA。")
        }
    }
    private func commitAirPlayRouteIfNeeded() {
        guard !systemPlayback, airPlayRouteSelected, let item = airPlayCandidate else { return }
        let token = airPlayToken, requestToken = generation
        if !airPlayStarting {
            airPlayStarting = true; airPlayPreparing = true
            airPlayResumePosition = currentRequest?.isLive == true ? 0 : position; airPlayResumePaused = !playing
            airPlayMessage = "已选择 AirPlay 设备，正在等待视频开始播放…"
            // Starting the external transport must not depend on a seek callback
            // from a paused remote player. Mute the candidate during handoff so
            // the current decoder is the only audible local playback.
            player.isMuted = true; player.playImmediately(atRate: rate)
            airPlayTimeout?.cancel()
            airPlayTimeout = Task { @MainActor [weak self, weak item] in
                let deadline = Date().addingTimeInterval(self?.airPlayStartTimeout ?? 25)
                var previous: Double?
                while Date() < deadline {
                    do { try await Task.sleep(nanoseconds: 100_000_000) } catch { return }
                    guard let self, let item, self.airPlayToken == token, self.generation == requestToken, self.player.currentItem === item else { return }
                    if item.status == .failed { self.failAirPlay("AirPlay 无法读取这段视频，本机继续播放。可尝试 DLNA。", error: item.error); return }
                    self.commitAirPlayRouteIfNeeded()
                    guard self.airPlaySeekCompleted, item.status == .readyToPlay else { continue }
                    let clock = self.player.currentTime().seconds
                    if clock.isFinite, let previous, clock > previous + 0.15, self.player.timeControlStatus == .playing {
                        self.airPlayResumePaused = !self.playing
                        self.nativeSession?.pause(); self.mpvSession?.pause()
                        self.systemPlayback = true; self.videoSurface.setSystemPlayback(true)
                        self.airPlayConnected = true; self.airPlayPreparing = false; self.airPlayMessage = nil
                        self.airPlayCandidate = nil; self.airPlayStarting = false
                        self.player.isMuted = self.nativeMuted
                        if self.airPlayResumePaused { self.player.pause() }
                        self.endToken = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main) { [weak self] _ in
                            Task { @MainActor in if self?.generation == requestToken { self?.onEnd?() } }
                        }
                        return
                    }
                    if previous == nil, clock.isFinite { previous = clock }
                }
                guard let self, self.airPlayToken == token else { return }
                self.failAirPlay("电视未开始播放，AirPlay 连接超时。本机继续播放，可尝试“安卓电视 · DLNA”。")
            }
        }
        guard item.status == .readyToPlay, !airPlaySeekStarted else { return }
        airPlaySeekStarted = true
        airPlayResumePosition = currentRequest?.isLive == true ? 0 : position
        guard airPlayResumePosition > 0 else { airPlaySeekCompleted = true; return }
        let tolerance = CMTime(seconds: 0.5, preferredTimescale: 600)
        player.seek(to: CMTime(seconds: airPlayResumePosition, preferredTimescale: 600), toleranceBefore: tolerance, toleranceAfter: tolerance) { [weak self] success in
            Task { @MainActor in
                guard let self, self.airPlayToken == token else { return }
                self.airPlaySeekTimeout?.cancel(); self.airPlaySeekTimeout = nil
                guard success else { self.failAirPlay("电视未能恢复播放进度，本机继续播放。可尝试 DLNA。"); return }
                self.airPlaySeekCompleted = true; self.player.playImmediately(atRate: self.rate)
            }
        }
        airPlaySeekTimeout = Task { @MainActor [weak self] in
            do { try await Task.sleep(nanoseconds: 8_000_000_000) } catch { return }
            guard let self, self.airPlayToken == token, !self.airPlaySeekCompleted else { return }
            self.failAirPlay("电视没有响应播放进度定位，本机继续播放。可尝试 DLNA。")
        }
    }
    private func failAirPlay(_ message: String, error: Error? = nil) {
        let diagnostic = PlaybackFailure(error: error, mediaStatusCodes: player.currentItem?.errorLog()?.events.map(\.errorStatusCode) ?? []).diagnostic
        let restore = systemPlayback && (nativeSession != nil || mpvSession != nil)
        let clock = player.currentTime().seconds, paused = airPlayResumePaused
        if restore { systemPlayback = false; videoSurface.setSystemPlayback(false) }
        cancelAirPlayPreparation()
        if systemPlayback {
            player.allowsExternalPlayback = false; player.isMuted = nativeMuted
            if paused { player.pause() } else { player.playImmediately(atRate: rate) }
        }
        if restore {
            if clock.isFinite { seek(to: clock) }
            if !paused { nativeSession?.play(); mpvSession?.play() }
        }
        airPlayMessage = message; airPlayDiagnostic = diagnostic.isEmpty ? nil : diagnostic
    }
    func useVLCPlayback() {
        guard systemPlayback, let request = currentRequest else { return }
        let resume = position, paused = ready && !playing
        nativeVolume = volume; nativeMuted = muted
        if nativeSession != nil || mpvSession != nil {
            stopPresentation(); player.pause(); clearAsset(); player.replaceCurrentItem(with: nil)
            systemPlayback = false; videoSurface.setSystemPlayback(false); cancelAirPlayPreparation()
            seek(to: request.isLive ? 0 : resume)
            if !paused { nativeSession?.play(); mpvSession?.play() }
            return
        }
        stopPresentation(); clearAttempt(); systemPlayback = false
        videoSurface.setSystemPlayback(false)
        begin(request.episode, headers: request.headers, position: request.isLive ? 0 : resume, isLive: request.isLive, resumePaused: paused)
    }
    func togglePictureInPicture() {
        guard dlna.selectedDevice == nil else { return }
        guard videoSurface.pictureInPictureSupported else { videoSurface.pictureInPictureError = "此设备暂不支持系统画中画。"; return }
        if !systemPlayback { pendingPiP = true; useSystemPlayback() }
        else { videoSurface.togglePictureInPicture() }
    }
    private var storedVideoSurface: PersistentVideoSurface?
    var videoSurface: PersistentVideoSurface {
        if let storedVideoSurface { return storedVideoSurface }
        let surface = PersistentVideoSurface(player: player); storedVideoSurface = surface; return surface
    }
    func stopPresentation() { storedVideoSurface?.stopPictureInPicture() }
    func prepareSpiderPlayback() {
        stopPresentation(); stop(); error = nil; failure = nil
        connectionStartedAt = Date(); connectingMessage = "正在解析播放地址…"
    }
    @Published var error: String?
    @Published var failure: PlaybackFailure?
    @Published var ready = false
    @Published var rate: Float = 1
    @Published var usingCompatibility = false
    @Published var connectingMessage = "正在连接视频…"
    @Published private(set) var connectionStartedAt = Date()
    @Published private(set) var buffering = false
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
    private var mpvLoadTask: Task<Void, Never>?
    private var mpvNetworkTask: Task<Void, Never>?
    private var mpvNetworkRelay: CastMediaRelay?
    private var mpvConnectionMemory = PlaybackConnectionMemory()
    private var mpvPreferredNetworkAttempt = false
    private var livePlan: LiveRoutePlan?
    private var liveHeaders: [String: String] = [:]
    private var onLiveRoute: ((Int) -> Void)?
    private struct PlaybackRequest {
        let episode: Episode
        let headers: [String: String]
        let position: Double
        let isLive: Bool
        let resumePaused: Bool
    }
    private var currentRequest: PlaybackRequest?
    private var tlsRetryAttempted = false
    private var tlsRetryTask: Task<Void, Never>?
    private var pendingKeyboardSeek: Double?
    private var keyboardSeekGeneration = UUID()
    init(airPlayStartTimeout: TimeInterval = 25) {
        self.airPlayStartTimeout = airPlayStartTimeout.isFinite ? max(1, airPlayStartTimeout) : 25
        player.allowsExternalPlayback = true
        routeObservation = player.observe(\.isExternalPlaybackActive, options: [.new]) { [weak self] _, _ in
            Task { @MainActor in
                guard let self else { return }; self.airPlayRouteChanged(self.player.isExternalPlaybackActive)
            }
        }
        dlna.onEnd = { [weak self] in self?.onEnd?() }
        clockTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(nanoseconds: 5_000_000_000) } catch { return }
                guard let self else { return }; if self.ready { self.onProgress?(self.position) }
            }
        }
    }
    func play(_ episode: Episode, headers: [String: String], position: Double = 0, isLive: Bool = false) {
        let cast = dlna.selectedDevice
        let keepSystemOutput = systemPlayback && (videoSurface.externalPlaybackActive || videoSurface.pictureInPictureActive)
        stop(); systemPlayback = keepSystemOutput; error = nil; failure = nil; ready = false
        pendingCastDevice = cast
        begin(episode, headers: headers, position: position, isLive: isLive)
    }
    func playLive(_ episodes: [Episode], index: Int, headers: [String: String], onRoute: @escaping (Int) -> Void) {
        let cast = dlna.selectedDevice
        let keepSystemOutput = systemPlayback && (videoSurface.externalPlaybackActive || videoSurface.pictureInPictureActive)
        stop(); systemPlayback = keepSystemOutput; error = nil; failure = nil
        pendingCastDevice = cast
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
    private func begin(_ episode: Episode, headers: [String: String], position: Double = 0, isLive: Bool, retryingTLS: Bool = false, resumePaused: Bool = false, retryWithSystemNetwork: Bool = false) {
        currentRequest = PlaybackRequest(episode: episode, headers: headers, position: position, isLive: isLive, resumePaused: resumePaused)
        tlsRetryAttempted = retryingTLS
        guard let url = URL(string: episode.url), ["http", "https", "file", "rtsp", "rtmp"].contains(url.scheme?.lowercased() ?? "") else {
            finishFailure(PlaybackFailure(error: URLError(.unsupportedURL))); return
        }
        let token = UUID(); generation = token
        connectionStartedAt = Date()
        connectingMessage = connectionText(retryingTLS ? "正在重新连接片源…" : "正在连接片源…")
        componentNotice = nil
        if !systemPlayback && preferMPV {
            let canRelay = !isLive && ["http", "https"].contains(url.scheme?.lowercased() ?? "")
            let remembered = canRelay && !retryingTLS && mpvConnectionMemory.prefersCompatibility(for: url, headers: headers)
            if canRelay && (retryWithSystemNetwork || remembered) {
                mpvPreferredNetworkAttempt = remembered
                loadMPVWithSystemNetwork(url, headers: headers, position: position, token: token, resumePaused: resumePaused)
                return
            }
            mpvLoadTask = Task { @MainActor [weak self] in
                guard let self else { return }
                do { try await self.loadMPV(url, headers: headers, position: position, token: token, resumePaused: resumePaused) }
                catch {
                    guard !Task.isCancelled, self.generation == token else { return }
                    self.componentNotice = "IINA 播放组件不可用，已回退内置 VLC。"
                    self.loadDefaultPlayer(url, episode: episode, headers: headers, position: position, isLive: isLive, token: token, resumePaused: resumePaused)
                }
            }
            return
        }
        loadDefaultPlayer(url, episode: episode, headers: headers, position: position, isLive: isLive, token: token, resumePaused: resumePaused)
    }
    private func loadDefaultPlayer(_ url: URL, episode: Episode, headers: [String: String], position: Double, isLive: Bool, token: UUID, resumePaused: Bool) {
        if !systemPlayback {
            let supported = Set(["user-agent", "referer", "referrer"])
            if headers.keys.contains(where: { !supported.contains($0.lowercased()) }) { systemPlayback = true }
        }
        videoSurface.setSystemPlayback(systemPlayback)
        if !systemPlayback {
            loadVLC(url, headers: headers, position: position, token: token, resumePaused: resumePaused); return
        }
        if isLive && url.pathExtension.lowercased() == "flv" {
            startCompatibility(episode, headers: headers, token: token); return
        }
        loadAsset(url, headers: headers, position: position, token: token, fallback: isLive ? episode : nil, resumePaused: resumePaused)
    }
    private func loadVLC(_ url: URL, headers: [String: String], position: Double, token: UUID, resumePaused: Bool) {
        connectingMessage = connectionText(tlsRetryAttempted ? "正在重新连接片源…" : "正在连接片源…")
        let session = VLCPlaybackSession(url: url, headers: headers, drawable: videoSurface.view.prepareVLCView(), position: position, paused: resumePaused, rate: rate, volume: nativeVolume, muted: nativeMuted)
        nativeSession = session
        session.onState = { [weak self, weak session] state in
            guard let self, let session, self.generation == token, self.nativeSession === session else { return }
            switch state {
            case .opening:
                if !self.ready { self.connectingMessage = self.connectionText("正在等待片源响应…") }
            case .buffering:
                self.buffering = self.ready && session.playing
                if !self.ready { self.connectingMessage = self.connectionText("正在准备视频画面…") }
            case .playing, .esAdded:
                self.buffering = false
                self.markNativeReady(session)
            case .paused:
                self.buffering = false
            case .error:
                self.handleNativeFailure(token: token)
            case .ended:
                if self.currentRequest?.isLive == true || !self.ready || (session.duration <= 0 && session.position < 0.2) {
                    self.handleNativeFailure(token: token)
                } else { self.onEnd?() }
            default: break
            }
        }
        connectionTimeout = Task { @MainActor [weak self] in
            for _ in 0..<150 {
                do { try await Task.sleep(nanoseconds: 100_000_000) } catch { return }
                guard let self, self.generation == token, self.nativeSession === session, !self.ready else { return }
                self.markNativeReady(session)
                if self.ready { return }
            }
            guard let self, self.generation == token, !self.ready else { return }
            self.handleNativeFailure(token: token, error: session.player.state == .opening ? URLError(.timedOut) : nil)
        }
        session.start()
    }
    private func loadMPV(_ url: URL, headers: [String: String], position: Double, token: UUID, resumePaused: Bool) async throws {
        let session = try await MPVPlaybackSession.make(url: url, headers: headers, position: position, paused: resumePaused, rate: rate, volume: nativeVolume, muted: nativeMuted)
        guard !Task.isCancelled, generation == token else { session.stop(); throw CancellationError() }
        session.setRate(rate); session.setVolume(nativeVolume); session.setMuted(nativeMuted)
        mpvSession = session; videoSurface.view.setMPVView(session.renderingView)
        var deliveredEnd = false
        session.onUpdate = { [weak self, weak session] state in
            guard let self, let session, self.generation == token, self.mpvSession === session else { return }
            if state.failure < 0 {
                self.handleNativeFailure(token: token, error: NSError(domain: "mpv", code: Int(state.failure)))
                return
            }
            let buffering = self.ready && state.buffering && !state.paused
            if self.buffering != buffering { self.buffering = buffering }
            if state.ready && !self.ready {
                if self.mpvNetworkRelay != nil, let request = self.currentRequest, !request.isLive, let source = URL(string: request.episode.url) {
                    self.mpvConnectionMemory.rememberCompatibility(for: source, headers: request.headers)
                }
                self.ready = true; self.connectionTimeout?.cancel(); self.connectionTimeout = nil; self.becameReady()
            }
            if !state.ended { deliveredEnd = false }
            if state.ended && self.ready && !deliveredEnd {
                deliveredEnd = true
                if self.currentRequest?.isLive == true { self.handleNativeFailure(token: token) } else { self.onEnd?() }
            }
        }
        connectionTimeout = Task { [weak self] in
            // The compatibility attempt may need to fetch both a master and
            // media playlist before it can deliver the first decoded frame.
            let seconds: UInt64 = self?.mpvNetworkRelay == nil ? 12 : 25
            do { try await Task.sleep(nanoseconds: seconds * 1_000_000_000) } catch { return }
            guard let self, self.generation == token, !self.ready else { return }
            self.handleNativeFailure(token: token, error: URLError(.timedOut))
        }
        session.start()
    }
    private func loadMPVWithSystemNetwork(_ url: URL, headers: [String: String], position: Double, token: UUID, resumePaused: Bool) {
        connectingMessage = mpvPreferredNetworkAttempt ? "正在使用上次成功的兼容连接…" : "正在尝试兼容连接（1/1）…"
        // URLSession handles HTTPS, system proxies and redirects; libmpv keeps
        // decoding/rendering inside TVBox. The endpoint is loopback-only and
        // is torn down with this playback attempt, never shared with a TV.
        let relay = CastMediaRelay(source: url, headers: headers, peer: "127.0.0.1")
        mpvNetworkRelay = relay
        mpvNetworkTask = Task { @MainActor [weak self] in
            do {
                let input = try await relay.start()
                try Task.checkCancellation()
                guard let self, self.generation == token else { relay.stop(); return }
                try await self.loadMPV(input, headers: [:], position: position, token: token, resumePaused: resumePaused)
                guard !Task.isCancelled, self.generation == token else { relay.stop(); return }
                self.componentNotice = self.mpvPreferredNetworkAttempt ? "已复用成功连接 · IINA 播放组件" : "已启用兼容连接 · IINA 播放组件"
            } catch {
                relay.stop()
                guard !Task.isCancelled, let self, self.generation == token else { return }
                self.handleNativeFailure(token: token, error: error)
            }
        }
    }
    private func markNativeReady(_ session: VLCPlaybackSession) {
        // VLC can enter Playing for an HTML/playlist response without opening
        // a decoder. A real audio or video track is required before hiding the
        // connection state and cancelling its timeout.
        guard !ready, nativeSession === session,
              session.player.hasVideoOut || session.player.numberOfAudioTracks > 0 else { return }
        ready = true; connectionTimeout?.cancel(); connectionTimeout = nil; becameReady()
    }
    private func handleNativeFailure(token: UUID, error: Error? = nil) {
        guard generation == token, let request = currentRequest else { return }
        if mpvNetworkRelay != nil, let url = URL(string: request.episode.url) {
            mpvConnectionMemory.forget(url, headers: request.headers)
        }
        // Retry once, preserving the route, headers and user state. Only an
        // actual mpv failure uses the system-network compatibility attempt;
        // absent/incompatible IINA components must keep retrying with VLC.
        if !tlsRetryAttempted {
            let resume = ready ? position : request.position, paused = ready ? !playing : request.resumePaused
            let failedPreferred = mpvPreferredNetworkAttempt
            let retryWithSystemNetwork = !failedPreferred && mpvSession != nil && !request.isLive && ["http", "https"].contains(URL(string: request.episode.url)?.scheme?.lowercased() ?? "")
            clearAttempt(); tlsRetryAttempted = true
            connectionStartedAt = Date()
            connectingMessage = connectionText(failedPreferred ? "兼容连接暂不可用，正在尝试直接连接…" : "连接暂未成功，正在自动重试（1/1）…")
            let retryToken = generation
            tlsRetryTask = Task { @MainActor [weak self] in
                // A different network path needs no same-endpoint backoff.
                if !retryWithSystemNetwork && !failedPreferred {
                    do { try await Task.sleep(nanoseconds: 700_000_000) } catch { return }
                }
                guard let self, self.generation == retryToken else { return }
                self.begin(request.episode, headers: request.headers, position: request.isLive ? 0 : resume, isLive: request.isLive, retryingTLS: true, resumePaused: paused, retryWithSystemNetwork: retryWithSystemNetwork)
            }
        } else { finishFailure(PlaybackFailure(error: error)) }
    }
    private func loadAsset(_ url: URL, headers: [String: String], position: Double, token: UUID, fallback: Episode?, resumePaused: Bool = false) {
        player.allowsExternalPlayback = true
        connectionTimeout?.cancel()
        if livePlan != nil {
            connectionTimeout = Task { [weak self] in
                do { try await Task.sleep(nanoseconds: 15_000_000_000) } catch { return }
                guard let self, self.generation == token, !self.ready else { return }
                self.finishFailure(PlaybackFailure(error: URLError(.timedOut)))
            }
        }
        player.volume = Float(nativeVolume); player.isMuted = nativeMuted
        let asset = AVURLAsset(url: url, options: headers.isEmpty ? nil : ["AVURLAssetHTTPHeaderFieldsKey": headers])
        let item = AVPlayerItem(asset: asset)
        if usingCompatibility { item.preferredForwardBufferDuration = 3 }
        status = item.observe(\.status, options: [.new, .initial]) { [weak self] item, _ in
            Task { @MainActor in
                guard let self, self.generation == token else { return }
                if item.status == .failed { self.handleFailure(item.error, item: item, fallback: fallback, headers: headers) }
                if item.status == .readyToPlay {
                    self.connectionTimeout?.cancel(); self.connectionTimeout = nil
                    let finish: () -> Void = { [weak self, weak item] in
                        guard let self, self.generation == token, self.player.currentItem === item else { return }
                        self.ready = true
                        if resumePaused { self.player.pause() } else { self.player.playImmediately(atRate: self.rate) }
                        self.becameReady()
                        if self.pendingPiP { self.pendingPiP = false; self.videoSurface.requestPictureInPicture() }
                    }
                    if position.isFinite && position > 0 {
                        self.player.seek(to: CMTime(seconds: position, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero) { _ in
                            Task { @MainActor in finish() }
                        }
                    } else { finish() }
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
    private func becameReady() {
        onReady?()
        if let device = pendingCastDevice { pendingCastDevice = nil; cast(to: device) }
    }
    func cast(to device: DLNADevice) {
        guard ready, let request = currentRequest, let url = URL(string: request.episode.url), !videoSurface.externalPlaybackActive else { return }
        cancelAirPlayPreparation()
        let previous = castTask; previous?.cancel()
        let resume = position, paused = !playing, token = generation
        castTask = Task { [weak self] in
            await previous?.value
            guard let self, self.generation == token, !Task.isCancelled else { return }
            do {
                try await self.dlna.connect(to: device, source: url, headers: request.headers, title: request.episode.name,
                                            position: request.isLive ? 0 : resume, paused: paused, isLive: request.isLive)
                guard self.generation == token, !Task.isCancelled else { return }
                // Only mute the local decoder after the television confirms playback.
                self.player.pause(); self.nativeSession?.pause(); self.mpvSession?.pause()
            } catch {}
        }
    }
    func returnToLocal() {
        guard dlna.selectedDevice != nil else { return }
        let remote = dlna.hasPlayed ? dlna.state : nil
        castTask?.cancel(); castTask = nil; pendingCastDevice = nil; dlna.disconnect()
        guard let request = currentRequest else { return }
        if request.isLive, remote != nil {
            clearAttempt(); begin(request.episode, headers: request.headers, isLive: true)
        } else if let remote {
            seek(to: remote.position)
            if remote.playing { if systemPlayback { player.playImmediately(atRate: rate) } else { nativeSession?.play(); mpvSession?.play() } }
            else { if systemPlayback { player.pause() } else { nativeSession?.pause(); mpvSession?.pause() } }
        }
    }
    func stop() {
        dlna.stopSearch()
        castTask?.cancel(); castTask = nil; pendingCastDevice = nil; dlna.disconnect()
        livePlan = nil; liveHeaders = [:]; onLiveRoute = nil
        pendingPiP = false
        clearAttempt()
        systemPlayback = false; storedVideoSurface?.setSystemPlayback(false)
    }
    private func clearAttempt() {
        cancelAirPlayPreparation()
        mpvLoadTask?.cancel(); mpvLoadTask = nil
        mpvNetworkTask?.cancel(); mpvNetworkTask = nil
        mpvNetworkRelay?.stop(); mpvNetworkRelay = nil
        mpvPreferredNetworkAttempt = false
        buffering = false
        nativeSeekTask?.cancel(); nativeSeekTask = nil
        nativeSession?.stop(); nativeSession = nil; mpvSession?.stop(); mpvSession = nil; storedVideoSurface?.view.setMPVView(nil)
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
    func setRate(_ value: Float) { guard value.isFinite, value > 0, value <= 4, !dlna.connected else { return }; rate = value; if systemPlayback { if player.rate != 0 { player.rate = value } } else { nativeSession?.setRate(value); mpvSession?.setRate(value) } }
    @discardableResult func seekRelative(by seconds: Double) -> Bool {
        guard canSeek, livePlan == nil, seconds.isFinite else { return false }
        let target = min(max(0, (pendingKeyboardSeek ?? position) + seconds), duration)
        pendingKeyboardSeek = target
        nativeSeekTask?.cancel()
        let token = generation
        nativeSeekTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(nanoseconds: 80_000_000) } catch { return }
            guard let self, self.generation == token else { return }
            self.seek(to: target)
        }
        return true
    }
    deinit {
        airPlayTimeout?.cancel(); airPlaySeekTimeout?.cancel()
        if let observer = airPlayFailureObserver { NotificationCenter.default.removeObserver(observer) }
        castTask?.cancel()
        clockTask?.cancel(); nativeSeekTask?.cancel()
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
    @Published var playbackPreference: PlaybackPreference {
        didSet { defaults.set(playbackPreference.rawValue, forKey: "playback.preference.v1") }
    }
    let player = PlayerController()
    let fullscreen: PlaybackFullscreenPresenter
    let service: TVService
    let cspRuntime: CSPBundledRuntime
    let liveBrowser: LiveBrowserState
    let networkProbe = NetworkProbeModel()
    let updates = AppUpdateController(enabled: !ProcessInfo.processInfo.arguments.contains("--ui-test"))
    private var catalogTask: Task<Void, Never>?
    private var liveTask: Task<Void, Never>?
    private var resolutionTask: Task<Void, Never>?
    private var resolutionID = UUID()
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
    var supportedSites: [Site] { configuration?.sites.filter { service.supports($0) } ?? [] }
    init(fullscreen: PlaybackFullscreenPresenter? = nil) {
        self.fullscreen = fullscreen ?? PlaybackFullscreenPresenter()
        let assets = (Bundle.main.resourceURL ?? Bundle.main.bundleURL).appendingPathComponent("CSPRuntime", isDirectory: true)
        let storage: URL
        if ProcessInfo.processInfo.arguments.contains("--ui-test") {
            storage = FileManager.default.temporaryDirectory.appendingPathComponent("tvbox-csp-ui-" + UUID().uuidString)
        } else {
            storage = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("TVBoxMac/CSPRuntime", isDirectory: true)
        }
        let runtime = CSPBundledRuntime(assets: assets, storage: storage)
        cspRuntime = runtime
        service = TVService(csp: runtime.available ? CSPRPCTransport(runtime: runtime) : nil)
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
        playbackPreference = PlaybackPreference(rawValue: defaults.string(forKey: "playback.preference.v1") ?? "")
            ?? (ProcessInfo.processInfo.arguments.contains("--ui-test") ? .builtIn : .preferIINA)
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
    func resetCSPComponent(sourceID: String, siteID: String) {
        do {
            try sourceLibrary.setCSPComponent(nil, sourceID: sourceID, siteID: siteID)
            persistLibrary()
            if playback?.site?.key == sourceID + "::" + siteID { stop() }
            if sourceLibrary.selectedVODID == sourceID && self.siteID == siteID { refresh() }
        } catch { alert = error.localizedDescription }
    }
    @Published var catalogNeedsRepositorySelection = false
    func refresh(append: Bool = false) {
        catalogTask?.cancel(); requestID = UUID(); let token = requestID
        catalogError = nil; catalogNeedsRepositorySelection = false
        if !append { page = 1; videos = []; categories = [] }
        if isDemo {
            videos = Demo.videos.filter { submittedQuery.isEmpty || $0.title.localizedCaseInsensitiveContains(submittedQuery) }; loading = false; pageCount = 1; return
        }
        guard let source = selectedVODSource, site != nil else { loading = false; return }
        loading = true
        let selectedCategory = category; let search = submittedQuery; let targetPage = append ? page + 1 : 1
        let selectedSiteID = siteID
        catalogTask = Task {
            do {
                let loaded = try await service.catalogRefreshingCSP(source: source, siteID: selectedSiteID, category: selectedCategory, search: search, page: targetPage)
                let result = loaded.catalog
                guard !Task.isCancelled, requestID == token else { return }
                if let refreshed = loaded.refreshed {
                    guard sourceLibrary.vodSources.first(where: { $0.id == source.id }) == source else { loading = false; return }
                    try sourceLibrary.replaceVOD(source.id, configuration: refreshed.configuration, name: source.name)
                    persistLibrary()
                }
                categories = loaded.categories ?? result.categories
                if append { var ids = Set(videos.map(\.id)); videos += result.videos.filter { ids.insert($0.id).inserted } } else { videos = result.videos }
                page = targetPage; pageCount = result.pageCount; loading = false
            } catch {
                guard !Task.isCancelled, requestID == token else { return }
                catalogNeedsRepositorySelection = (error as? CSPFailure) == .entryClassMissing
                catalogError = L10n.string(error.localizedDescription); loading = false
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
        let panel = NSOpenPanel(); panel.title = L10n.text("导入 TVBox 配置或直播列表"); panel.allowedContentTypes = [.json, .plainText, UTType(filenameExtension: "m3u") ?? .text, UTType(filenameExtension: "m3u8") ?? .text]; panel.canChooseDirectories = false
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
        if result.updatedVOD && !config.sites.isEmpty && !config.sites.contains(where: { service.supports($0) }) {
            let keptExisting = previousVODID != nil && sourceLibrary.selectedVODID == previousVODID && config.location != selectedVODSource?.origin
            importNotice = "配置已保存：\(config.sites.count) 个点播接口暂不可调用。Java / CSP 接口需要完整运行时和有效的 spider 配置；旧配置请先刷新一次。" + (keptExisting ? "原点播源保持选中。" : "可在下方查看兼容状态。") + (result.updatedLive ? "另已保存直播来源，可在“电视直播”页选择。" : "")
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
    func sourceAddress(_ id: String, live: Bool) -> String? {
        if live { return liveSources.first { $0.id == id }.map { $0.feedURL ?? $0.configuration.location } }
        return vodSources.first { $0.id == id }?.configuration.location
    }
    func copySourceAddress(_ id: String, live: Bool, pasteboard: NSPasteboard = .general) {
        guard let address = sourceAddress(id, live: live), !address.isEmpty else { return }
        pasteboard.clearContents()
        pasteboard.setString(address, forType: .string)
    }
    func updateSource(_ id: String, live: Bool, name: String, address: String) async throws {
        guard !refreshingSources.contains(id) else { throw TVError.message("这个源正在刷新，请稍后再修改。") }
        let oldVOD = vodSources.first { $0.id == id }
        let oldLive = liveSources.first { $0.id == id }
        guard let originalAddress = sourceAddress(id, live: live) else { throw TVError.message("这个源已被移除，请重新打开配置管理。") }
        let label = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !label.isEmpty else { throw TVError.message("请输入源名称。") }
        let text = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: text), ["http", "https", "file"].contains(url.scheme?.lowercased() ?? ""),
              url.isFileURL || !(url.host ?? "").isEmpty else {
            throw TVError.message("请输入完整的 http://、https:// 或本地 file:// 地址。")
        }
        try Task.checkCancellation()
        // A name-only edit works offline and never interrupts playback.
        if url.absoluteString == originalAddress {
            renameSource(id, name: label, live: live); return
        }
        refreshingSources.insert(id)
        defer { refreshingSources.remove(id) }
        let config: Configuration
        if live, var feed = oldLive?.feeds.first {
            // An individual subscription keeps its UA, authorization and EPG
            // defaults. Validate the replacement before touching saved state.
            feed.url = url.absoluteString; feed.name = label
            _ = try await service.channels(feed: feed)
            config = Configuration(name: label, location: url.absoluteString, feeds: [feed])
        } else { config = try await service.configuration(at: url) }
        try Task.checkCancellation()
        guard live ? liveSources.first(where: { $0.id == id }) == oldLive : vodSources.first(where: { $0.id == id }) == oldVOD else {
            throw TVError.message("这个源在验证期间已被修改或移除，请重新打开后再保存。")
        }
        if live { try sourceLibrary.replaceLive(id, configuration: config, name: label) }
        else { try sourceLibrary.replaceVOD(id, configuration: config, name: label) }
        persistLibrary()
        if live {
            channelCache.removeValue(forKey: id); cacheOrder.removeAll { $0 == id }
            if sourceLibrary.selectedLiveID == id {
                if playback?.isLive == true { stop() }
                liveBrowser.reset(); liveNavigation = []; refreshLive()
            }
        } else if sourceLibrary.selectedVODID == id {
            if playback?.isLive == false { stop() }
            siteID = sourceLibrary.activeVOD?.selectedSiteID ?? ""; category = ""; query = ""; submittedQuery = ""; refresh()
        }
    }
    func refreshSource(_ id: String, live: Bool) async {
        let origin = live ? liveSources.first(where: { $0.id == id })?.origin : vodSources.first(where: { $0.id == id })?.origin
        guard let origin, let url = URL(string: origin), ["http", "https", "file"].contains(url.scheme ?? "") else { alert = "此源没有可刷新的配置地址。"; return }
        let oldVOD = vodSources.first { $0.id == id }
        let oldLive = liveSources.first { $0.id == id }
        let affectedIDs = Set(live ? liveSources.filter { $0.origin == origin }.map(\.id) : vodSources.filter { $0.origin == origin }.map(\.id))
        guard refreshingSources.isDisjoint(with: affectedIDs) else { return }
        refreshingSources.formUnion(affectedIDs)
        defer { refreshingSources.subtract(affectedIDs) }
        do {
            let config: Configuration
            if live, let saved = oldLive, let feed = saved.feeds.first, feed.url == origin {
                _ = try await service.channels(feed: feed)
                config = Configuration(name: saved.configuration.name, location: origin, feeds: [feed])
            } else { config = try await service.configuration(at: url, reload: true) }
            // A source removed while its refresh was running must stay removed.
            guard live ? liveSources.first(where: { $0.id == id }) == oldLive : vodSources.first(where: { $0.id == id }) == oldVOD else { return }
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
    private func refreshedSite(_ site: Site?) -> Site? {
        guard let site else { return nil }
        for source in vodSources {
            let prefix = source.id + "::"
            if site.key.hasPrefix(prefix), let refreshed = source.runtimeSite(String(site.key.dropFirst(prefix.count))) { return refreshed }
        }
        return site
    }
    func show(_ video: Video, site: Site?, resume: LibraryEntry? = nil) { detail = DetailSelection(video: video, site: refreshedSite(site), resume: resume) }
    func isFavorite(_ video: Video, site: Site?) -> Bool { favorites.contains { $0.id == LibraryEntry(video: video, site: site).id } }
    func toggleFavorite(_ video: Video, site: Site?) {
        let item = LibraryEntry(video: video, site: site)
        if favorites.contains(where: { $0.id == item.id }) { favorites.removeAll { $0.id == item.id } } else { favorites.insert(item, at: 0) }
        save(favorites, key: "favorites")
    }
    func clearHistory() { history = []; save(history, key: "history") }
    func play(video: Video, site: Site?, line: PlayLine, index: Int, position: Double = 0, headers: [String: String]? = nil, live: Bool = false) {
        guard line.episodes.indices.contains(index) else { return }
        saveCurrentPosition(); playback?.cspLease?.stop()
        playback = Playback(video: video, site: site, line: line, index: index, headers: headers ?? site?.headers ?? [:], isLive: live)
        detail = nil
        startPlayback(position: position)
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
        startPlayback(position: 0)
    }
    private func startInternalPlayback(position: Double) {
        guard let current = playback else { return }
        player.preferMPV = playbackPreference == .preferIINA
        if current.isLive && current.catchupProgramme == nil {
            player.playLive(current.line.episodes, index: current.index, headers: current.headers) { [weak self] route in self?.playback?.index = route }
        } else { player.play(current.resolvedEpisode ?? current.episode, headers: current.headers, position: position) }
    }
    private func startPlayback(position: Double, forceResolve: Bool = false) {
        resolutionTask?.cancel(); resolutionID = UUID(); let token = resolutionID
        guard let current = playback else { return }
        guard let site = current.site, site.requiresCSP, !current.isLive, forceResolve || current.resolvedEpisode == nil else {
            startInternalPlayback(position: position); return
        }
        playback?.resolvedEpisode = nil
        player.prepareSpiderPlayback()
        playback?.cspLease?.stop(); playback?.cspLease = nil
        resolutionTask = Task {
            do {
                let result = try await service.resolvePlayback(site: site, line: current.line, episode: current.episode)
                guard !Task.isCancelled, resolutionID == token, playback != nil else { return }
                playback?.resolvedEpisode = Episode(name: current.episode.name, url: result.url.absoluteString)
                playback?.headers = result.headers
                playback?.cspLease = result.lease
                startInternalPlayback(position: position)
            } catch {
                guard !Task.isCancelled, resolutionID == token, playback != nil else { return }
                player.error = error.localizedDescription
            }
        }
    }
    func useBuiltInPlayback() {
        guard playback != nil else { return }
        let position = player.position
        playbackPreference = .builtIn; startPlayback(position: position)
    }
    func useIINAPlayback() {
        guard playback != nil else { return }
        guard MPVLibrary.componentURL != nil else { alert = "没有找到 IINA 的播放组件，当前继续使用内置 VLC。"; return }
        let position = player.position
        saveCurrentPosition(); playbackPreference = .preferIINA
        startPlayback(position: position)
    }
    func retryPlayback() {
        guard let current = playback else { return }
        if let programme = current.catchupProgramme, let channel = playingChannel { playCatchup(programme, channel: channel); return }
        if current.isLive { play(video: current.video, site: current.site, line: current.line, index: current.index, headers: current.headers, live: true) }
        else { startPlayback(position: 0, forceResolve: true) }
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
        let position = player.position; if position.isFinite { saveProgress(position) }; save(history, key: "history")
    }
    func stop() { resolutionTask?.cancel(); resolutionID = UUID(); fullscreen.close(); saveCurrentPosition(); player.stopPresentation(); player.stop(); playback?.cspLease?.stop(); playback = nil }
    func shutdown() { resolutionTask?.cancel(); catalogTask?.cancel(); liveTask?.cancel(); playback?.cspLease?.stop(); cspRuntime.stop(); fullscreen.closeImmediately(); networkProbe.cancel(); saveCurrentPosition(); player.stopPresentation(); player.stop(); preferenceWriter.flush() }
    func copyURL() {
        guard let current = playback else { return }
        guard let url = current.resolvedEpisode?.url ?? (current.site?.requiresCSP == true ? nil : current.episode.url) else { alert = "播放地址尚未解析成功，请重试后复制。"; return }
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(url, forType: .string)
    }
}
