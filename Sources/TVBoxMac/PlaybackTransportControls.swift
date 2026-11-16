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
    @Published private(set) var effectiveRate: Float = 1
    @Published private(set) var canSeek = false
    @Published private(set) var canPause = true
    @Published private(set) var canVolume = true
    @Published private(set) var canMute = true
    @Published private(set) var casting = false
    @Published private(set) var remoteSelected = false
    @Published private(set) var remoteConnecting = false
    let controller: PlayerController
    private var clock: Task<Void, Never>?
    init(controller: PlayerController) {
        self.controller = controller
        clock = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                self?.refresh()
                do { try await Task.sleep(nanoseconds: 250_000_000) } catch { return }
            }
        }
        refresh()
    }
    func refresh() {
        if abs(position - controller.position) > 0.04 { position = controller.position }
        if duration != controller.duration { duration = controller.duration }
        if playing != controller.playing { playing = controller.playing }
        if volume != controller.volume { volume = controller.volume }
        if muted != controller.muted { muted = controller.muted }
        if effectiveRate != controller.effectiveRate { effectiveRate = controller.effectiveRate }
        if canSeek != controller.canSeek { canSeek = controller.canSeek }
        if canPause != controller.canPause { canPause = controller.canPause }
        if canVolume != controller.canVolume { canVolume = controller.canVolume }
        if canMute != controller.canMute { canMute = controller.canMute }
        if casting != controller.dlna.connected { casting = controller.dlna.connected }
        if remoteSelected != (controller.dlna.selectedDevice != nil) { remoteSelected = controller.dlna.selectedDevice != nil }
        if remoteConnecting != controller.dlna.connecting { remoteConnecting = controller.dlna.connecting }
    }
    func togglePlayback(rate: Float) { controller.togglePlayback(); refresh() }
    func seek(to value: Double) { controller.seek(to: value); refresh() }
    func setVolume(_ value: Double) { controller.setVolume(value); refresh() }
    func toggleMute() { controller.toggleMute(); refresh() }
    deinit { clock?.cancel() }

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
        _transport = StateObject(wrappedValue: PlaybackTransport(controller: controller))
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
                    }).accessibilityLabel("播放进度").disabled(!transport.canSeek)
                    Text(formatTime(transport.duration)).monospacedDigit().frame(minWidth: 38)
                }.font(.system(size: 10)).foregroundStyle(.white.opacity(0.8))
            }
            HStack(spacing: PlayerControlMetrics.spacing) {
                Group {
                Button { transport.togglePlayback(rate: controller.rate); activity() } label: { PlayerControlIcon(name: transport.playing ? "pause.fill" : "play.fill") }.help(transport.playing ? "暂停" : "播放").disabled(!transport.canPause || transport.remoteConnecting)
                if !live && transport.duration > 0 {
                    Button { transport.seek(to: transport.position - 15); activity() } label: { PlayerControlIcon(name: "gobackward.15") }.help("后退 15 秒").disabled(!transport.canSeek)
                    Button { transport.seek(to: transport.position + 15); activity() } label: { PlayerControlIcon(name: "goforward.15") }.help("前进 15 秒").disabled(!transport.canSeek)
                } else if live { Text("LIVE").font(.system(size: 10, weight: .semibold)).foregroundStyle(Theme.accent) }
                Spacer(minLength: 4)
                if controller.systemPlayback && !transport.remoteSelected {
                    if controller.canUseVLCPlayback {
                        Button("返回本机内核") { controller.useVLCPlayback(); activity() }.font(.system(size: 10)).help("恢复本机播放内核，结束系统投屏或画中画")
                    } else {
                        Text("兼容播放").font(.system(size: 10)).help("此地址的自定义鉴权请求头需要系统兼容播放通道")
                    }
                }
                Menu {
                    ForEach([Float(0.5), 1, 1.25, 1.5, 2], id: \.self) { rate in Button("\(String(format: "%g", rate))×") { controller.setRate(rate); activity() } }
                } label: { Text("\(String(format: "%g", transport.effectiveRate))×").font(.system(size: 11, weight: .medium)).frame(width: 48, height: PlayerControlMetrics.buttonSize) }.frame(width: 48, height: PlayerControlMetrics.buttonSize)
                    .disabled(transport.remoteSelected).help(transport.remoteSelected ? "DLNA 以正常速度播放" : "播放速度")
                HStack(spacing: 6) {
                    Button { transport.toggleMute(); activity() } label: { PlayerControlIcon(name: transport.muted || transport.volume == 0 ? "speaker.slash.fill" : "speaker.wave.2.fill") }.help("静音 / 恢复音量").disabled(!transport.canMute)
                    Slider(value: Binding(get: { transport.volume }, set: { transport.setVolume($0); activity() }), in: 0...1).frame(width: 72, height: PlayerControlMetrics.buttonSize).accessibilityLabel("音量").disabled(!transport.canVolume)
                }
                Button { controller.togglePictureInPicture(); activity() } label: { PlayerControlIcon(name: "pip.enter") }
                    .help("画中画（使用系统播放通道）").disabled(transport.remoteSelected)
                }.disabled(!controller.ready)
                CastingPicker(controller: controller, surface: surface, casting: controller.dlna) { selectingAirPlay = $0; activity() }
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
        .onChange(of: controller.systemPlayback) { _ in transport.refresh(); activity() }
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
