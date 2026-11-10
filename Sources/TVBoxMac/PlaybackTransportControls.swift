import SwiftUI
import AVFoundation

enum PlayerControlMetrics {
    static let iconSize: CGFloat = 18
    static let buttonSize: CGFloat = 32
    static let spacing: CGFloat = 10
    static let fullscreenWidth: CGFloat = 104
}

struct PlayerControlIcon: View {
    let name: String
    var body: some View {
        Image(systemName: name).resizable().scaledToFit()
            .font(.system(size: PlayerControlMetrics.iconSize, weight: .medium))
            .frame(width: PlayerControlMetrics.iconSize, height: PlayerControlMetrics.iconSize)
            .frame(width: PlayerControlMetrics.buttonSize, height: PlayerControlMetrics.buttonSize)
            .contentShape(Rectangle())
    }
}

/// Only this small controls view observes the clock; channel lists are not
/// invalidated by progress ticks. No AVKit floating control hierarchy is used.
@MainActor final class PlaybackTransport: ObservableObject {
    @Published private(set) var position: Double = 0
    @Published private(set) var duration: Double = 0
    @Published private(set) var playing = false
    @Published private(set) var volume: Double = 1
    @Published private(set) var muted = false
    let player: AVPlayer
    private var timeToken: Any?
    private var observations: [NSKeyValueObservation] = []
    init(player: AVPlayer) {
        self.player = player
        timeToken = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.5, preferredTimescale: 600), queue: .main) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        observations = [
            player.observe(\.rate, options: [.initial, .new]) { [weak self] _, _ in Task { @MainActor in self?.refresh() } },
            player.observe(\.volume, options: [.new]) { [weak self] _, _ in Task { @MainActor in self?.refresh() } },
            player.observe(\.isMuted, options: [.new]) { [weak self] _, _ in Task { @MainActor in self?.refresh() } },
            player.observe(\.currentItem, options: [.new]) { [weak self] _, _ in Task { @MainActor in self?.refresh() } }
        ]
        refresh()
    }
    func refresh() {
        let current = player.currentTime().seconds, total = player.currentItem?.duration.seconds ?? 0
        position = current.isFinite ? max(0, current) : 0
        duration = total.isFinite && total > 0 ? total : 0
        playing = player.rate != 0; volume = Double(player.volume); muted = player.isMuted
    }
    func togglePlayback(rate: Float) {
        if player.rate == 0 {
            if duration > 0, position >= duration - 0.05, let item = player.currentItem {
                player.seek(to: .zero) { [weak self, weak item] _ in
                    Task { @MainActor in
                        guard let self, self.player.currentItem === item else { return }
                        self.player.playImmediately(atRate: rate); self.refresh()
                    }
                }
            } else { player.playImmediately(atRate: rate) }
        } else { player.pause() }
        refresh()
    }
    func seek(to value: Double) {
        guard value.isFinite, duration > 0, let item = player.currentItem else { return }
        let target = min(max(0, value), duration)
        player.seek(to: CMTime(seconds: target, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero) { [weak self, weak item] _ in
            Task { @MainActor in guard let self, self.player.currentItem === item else { return }; self.refresh() }
        }
    }
    func setVolume(_ value: Double) { guard value.isFinite else { return }; player.volume = Float(min(1, max(0, value))); refresh() }
    func toggleMute() { player.isMuted.toggle(); refresh() }
    deinit { if let timeToken { player.removeTimeObserver(timeToken) } }
}

struct PlaybackTransportControls: View {
    @ObservedObject var controller: PlayerController
    @ObservedObject var surface: PersistentVideoSurface
    @StateObject private var transport: PlaybackTransport
    let live: Bool
    let isFullscreen: Bool
    let onToggleFullscreen: () -> Void
    @State private var visible = true
    @State private var hideTask: Task<Void, Never>?
    @State private var hoveringControls = false
    @State private var scrubbing = false
    @State private var draft: Double = 0
    @State private var selectingAirPlay = false
    init(controller: PlayerController, surface: PersistentVideoSurface, live: Bool, isFullscreen: Bool, onToggleFullscreen: @escaping () -> Void) {
        self.controller = controller; self.surface = surface; self.live = live
        self.isFullscreen = isFullscreen; self.onToggleFullscreen = onToggleFullscreen
        _transport = StateObject(wrappedValue: PlaybackTransport(player: controller.player))
    }
    private var shown: Bool { visible || !controller.ready || !transport.playing || hoveringControls || scrubbing || selectingAirPlay }
    var body: some View {
        VStack(spacing: 7) {
            if !live && transport.duration > 0 {
                HStack(spacing: 9) {
                    Text(formatTime(scrubbing ? draft : transport.position)).monospacedDigit().frame(minWidth: 38)
                    Slider(value: Binding(get: { min(max(0, scrubbing ? draft : transport.position), transport.duration) }, set: { draft = $0 }), in: 0...max(1, transport.duration), onEditingChanged: { editing in
                        if editing { draft = transport.position; scrubbing = true }
                        else { transport.seek(to: draft); scrubbing = false }
                        activity()
                    }).accessibilityLabel("播放进度").disabled(!controller.ready)
                    Text(formatTime(transport.duration)).monospacedDigit().frame(minWidth: 38)
                }.font(.system(size: 10)).foregroundStyle(.white.opacity(0.8))
            }
            HStack(spacing: PlayerControlMetrics.spacing) {
                Group {
                Button { transport.togglePlayback(rate: controller.rate); activity() } label: { PlayerControlIcon(name: transport.playing ? "pause.fill" : "play.fill") }.help(transport.playing ? "暂停" : "播放")
                if !live && transport.duration > 0 {
                    Button { transport.seek(to: transport.position - 15); activity() } label: { PlayerControlIcon(name: "gobackward.15") }.help("后退 15 秒")
                    Button { transport.seek(to: transport.position + 15); activity() } label: { PlayerControlIcon(name: "goforward.15") }.help("前进 15 秒")
                } else if live { Text("LIVE").font(.system(size: 10, weight: .semibold)).foregroundStyle(Theme.accent) }
                Spacer(minLength: 4)
                Menu {
                    ForEach([Float(0.5), 1, 1.25, 1.5, 2], id: \.self) { rate in Button("\(String(format: "%g", rate))×") { controller.setRate(rate); activity() } }
                } label: { Text("\(String(format: "%g", controller.rate))×").font(.system(size: 11, weight: .medium)).frame(width: 48, height: PlayerControlMetrics.buttonSize) }.frame(width: 48, height: PlayerControlMetrics.buttonSize)
                HStack(spacing: 6) {
                    Button { transport.toggleMute(); activity() } label: { PlayerControlIcon(name: transport.muted || transport.volume == 0 ? "speaker.slash.fill" : "speaker.wave.2.fill") }.help("静音 / 恢复音量")
                    Slider(value: Binding(get: { transport.volume }, set: { transport.setVolume($0); activity() }), in: 0...1).frame(width: 72, height: PlayerControlMetrics.buttonSize).accessibilityLabel("音量")
                }
                Button { surface.togglePictureInPicture(); activity() } label: { PlayerControlIcon(name: "pip.enter") }
                    .disabled(!surface.pictureInPicturePossible && !surface.pictureInPictureActive).help("画中画")
                HStack(spacing: 4) {
                    AirPlayRoutePicker(player: controller.player) { selectingAirPlay = $0; activity() }
                        .frame(width: 26, height: 26)
                        .frame(width: PlayerControlMetrics.buttonSize, height: PlayerControlMetrics.buttonSize)
                    Text(surface.externalPlaybackActive ? "投屏中" : "投屏").font(.system(size: 11, weight: .medium))
                }.frame(height: PlayerControlMetrics.buttonSize).foregroundStyle(surface.externalPlaybackActive ? Theme.accent : .white)
                    .help("AirPlay 投屏：将 Mac 和电视连接到同一网络，点击图标选择电视。")
                }.disabled(!controller.ready)
                Button { onToggleFullscreen(); activity() } label: {
                    HStack(spacing: 6) {
                        PlayerControlIcon(name: isFullscreen ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")
                        Text(isFullscreen ? "退出全屏" : "全屏").font(.system(size: 11, weight: .medium))
                    }.foregroundStyle(.white).frame(width: PlayerControlMetrics.fullscreenWidth, height: PlayerControlMetrics.buttonSize)
                        .background(.black.opacity(0.45), in: RoundedRectangle(cornerRadius: 7))
                }.help(isFullscreen ? "退出全屏（Esc）" : "全屏播放（Control + Command + F）")
            }.frame(height: PlayerControlMetrics.buttonSize).buttonStyle(.plain)
        }
        .foregroundStyle(.white).tint(Theme.accent).padding(.horizontal, 16).padding(.vertical, 10)
        .background(LinearGradient(colors: [.clear, .black.opacity(0.65)], startPoint: .top, endPoint: .bottom))
        .opacity(shown ? 1 : 0).allowsHitTesting(shown).animation(.easeOut(duration: 0.18), value: shown)
        .onHover { hoveringControls = $0; activity() }
        .onReceive(NotificationCenter.default.publisher(for: .playerSurfacePointerActivity, object: surface)) { _ in activity() }
        .onChange(of: transport.playing) { _ in activity() }
        .onChange(of: controller.ready) { ready in transport.refresh(); if !ready { scrubbing = false; draft = 0 } }
        .onAppear { activity() }.onDisappear { hideTask?.cancel() }
        .alert("画中画", isPresented: Binding(get: { surface.pictureInPictureError != nil }, set: { if !$0 { surface.pictureInPictureError = nil } })) { Button("知道了") { surface.pictureInPictureError = nil } } message: { Text(surface.pictureInPictureError ?? "") }
    }
    private func activity() {
        hideTask?.cancel(); visible = true
        hideTask = Task { @MainActor in
            do { try await Task.sleep(nanoseconds: 3_000_000_000) } catch { return }
            visible = false
        }
    }
}

extension Notification.Name { static let playerSurfacePointerActivity = Notification.Name("TVBox.playerSurfacePointerActivity") }
