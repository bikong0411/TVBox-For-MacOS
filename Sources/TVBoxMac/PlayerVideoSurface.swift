import AppKit
import AVKit
import VLCKit

/// One container for VLC and optional system output. Fullscreen moves the
/// container without detaching either decoder's rendering view.
@MainActor final class PersistentVideoSurface: NSObject, ObservableObject, AVPictureInPictureControllerDelegate {
    let view: VideoRenderingView
    @Published private(set) var pictureInPicturePossible = false
    @Published private(set) var pictureInPictureActive = false
    @Published var pictureInPictureError: String?
    @Published private(set) var externalPlaybackActive = false
    private var pip: AVPictureInPictureController?
    private var observations: [NSKeyValueObservation] = []
    private var fullscreenHost = false
    private var pendingPiP = false
    private var pipTimeout: Task<Void, Never>?
    var pictureInPictureSupported: Bool { pip != nil }
    func setSystemPlayback(_ value: Bool) { view.setSystemPlayback(value) }
    func setFullscreenHost(_ value: Bool) { fullscreenHost = value }
    init(player: AVPlayer) {
        view = VideoRenderingView(player: player); super.init()
        view.onPointerActivity = { [weak self] in
            guard let self else { return }; NotificationCenter.default.post(name: .playerSurfacePointerActivity, object: self)
        }
        if AVPictureInPictureController.isPictureInPictureSupported() {
            pip = AVPictureInPictureController(playerLayer: view.videoLayer); pip?.delegate = self
            if let pip {
                observations = [
                    pip.observe(\.isPictureInPicturePossible, options: [.initial, .new]) { [weak self] pip, _ in
                        Task { @MainActor in
                            guard let self else { return }
                            self.pictureInPicturePossible = pip.isPictureInPicturePossible
                            if self.pendingPiP && pip.isPictureInPicturePossible { self.pendingPiP = false; self.pipTimeout?.cancel(); pip.startPictureInPicture() }
                        }
                    },
                    pip.observe(\.isPictureInPictureActive, options: [.initial, .new]) { [weak self] pip, _ in
                        Task { @MainActor in self?.pictureInPictureActive = pip.isPictureInPictureActive }
                    }
                ]
            }
        }
        observations.append(player.observe(\.isExternalPlaybackActive, options: [.initial, .new]) { [weak self] player, _ in
            Task { @MainActor in self?.externalPlaybackActive = player.isExternalPlaybackActive }
        })
    }
    func attach(to host: VideoHostView) {
        // SwiftUI may update an outgoing host after the incoming one mounts.
        // Only the currently selected presentation is allowed to claim the view.
        guard host.isFullscreen == fullscreenHost else { return }
        guard view.superview !== host else { view.frame = host.bounds; return }
        CATransaction.begin(); CATransaction.setDisableActions(true)
        view.removeFromSuperview(); view.frame = host.bounds
        view.autoresizingMask = [.width, .height]; host.addSubview(view)
        CATransaction.commit()
    }
    func detach(from host: VideoHostView) { if view.superview === host { view.removeFromSuperview() } }
    func togglePictureInPicture() {
        guard let pip else { pictureInPictureError = "此设备暂不支持系统画中画。"; return }
        if pip.isPictureInPictureActive { pip.stopPictureInPicture() }
        else { requestPictureInPicture() }
    }
    func requestPictureInPicture() {
        guard let pip else { pictureInPictureError = "此设备暂不支持系统画中画。"; return }
        pipTimeout?.cancel()
        if pip.isPictureInPicturePossible { pip.startPictureInPicture() } else {
            pendingPiP = true
            pipTimeout = Task { [weak self] in
                do { try await Task.sleep(nanoseconds: 8_000_000_000) } catch { return }
                guard let self, self.pendingPiP else { return }
                self.pendingPiP = false; self.pictureInPictureError = "这个视频暂时无法开启画中画，可以继续在窗口或全屏中观看。"
            }
        }
    }
    func stopPictureInPicture() { pendingPiP = false; pipTimeout?.cancel(); if pip?.isPictureInPictureActive == true { pip?.stopPictureInPicture() } }
    nonisolated func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController, failedToStartPictureInPictureWithError error: Error) {
        Task { @MainActor [weak self] in self?.pictureInPictureError = "暂时无法启动画中画，请稍后重试。" }
    }
}

final class VideoRenderingView: NSView {
    let videoLayer = AVPlayerLayer()
    private(set) var vlcView = VLCVideoView(frame: .zero)
    private let systemView = NSView(frame: .zero)
    private var mpvView: MPVRenderingView?
    var onPointerActivity: (() -> Void)?
    private var pointerTracking: NSTrackingArea?
    init(player: AVPlayer) {
        super.init(frame: .zero); wantsLayer = true
        videoLayer.player = player; videoLayer.videoGravity = .resizeAspect
        videoLayer.backgroundColor = NSColor.black.cgColor
        layer?.backgroundColor = NSColor.black.cgColor
        vlcView.backColor = .black; vlcView.fillScreen = false
        addSubview(vlcView)
        systemView.wantsLayer = true; systemView.layer?.addSublayer(videoLayer)
        addSubview(systemView); systemView.isHidden = true
    }
    required init?(coder: NSCoder) { nil }
    func prepareVLCView() -> VLCVideoView {
        let next = VLCVideoView(frame: bounds)
        next.backColor = .black; next.fillScreen = false
        useVLCView(next)
        return next
    }
    func useVLCView(_ next: VLCVideoView) {
        vlcView.removeFromSuperview()
        next.removeFromSuperview()
        next.frame = bounds
        next.isHidden = !systemView.isHidden
        addSubview(next, positioned: .below, relativeTo: systemView)
        vlcView = next
    }
    func setMPVView(_ value: MPVRenderingView?) {
        mpvView?.removeFromSuperview(); mpvView = value
        if let value { value.frame = bounds; addSubview(value, positioned: .below, relativeTo: systemView) }
        vlcView.isHidden = value != nil || !systemView.isHidden
    }
    func setSystemPlayback(_ value: Bool) { systemView.isHidden = !value; vlcView.isHidden = value || mpvView != nil; mpvView?.isHidden = value }
    override func layout() {
        super.layout(); vlcView.frame = bounds; systemView.frame = bounds; mpvView?.frame = bounds
        CATransaction.begin(); CATransaction.setDisableActions(true); videoLayer.frame = systemView.bounds; CATransaction.commit()
    }
    override func hitTest(_ point: NSPoint) -> NSView? { bounds.contains(convert(point, from: superview)) ? self : nil }
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); window?.acceptsMouseMovedEvents = true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func updateTrackingAreas() {
        if let pointerTracking { removeTrackingArea(pointerTracking) }
        let area = NSTrackingArea(rect: .zero, options: [.activeAlways, .inVisibleRect, .mouseMoved, .mouseEnteredAndExited], owner: self, userInfo: nil)
        addTrackingArea(area); pointerTracking = area; super.updateTrackingAreas()
    }
    override func mouseEntered(with event: NSEvent) { onPointerActivity?() }
    override func mouseMoved(with event: NSEvent) { onPointerActivity?() }
    override func mouseDown(with event: NSEvent) {
        onPointerActivity?()
        let point = convert(event.locationInWindow, from: nil)
        let inControls = isFlipped ? point.y >= bounds.height - 84 : point.y <= 84
        if inControls { super.mouseDown(with: event); return }
        window?.makeFirstResponder(self)
        if event.clickCount >= 2 && event.clickCount.isMultiple(of: 2) { (superview as? VideoHostView)?.onToggleFullscreen?() }
    }
}

final class VideoHostView: NSView {
    weak var surface: PersistentVideoSurface?
    var onToggleFullscreen: (() -> Void)?
    let isFullscreen: Bool
    init(surface: PersistentVideoSurface, isFullscreen: Bool = false) { self.surface = surface; self.isFullscreen = isFullscreen; super.init(frame: .zero) }
    required init?(coder: NSCoder) { nil }
    override func layout() { super.layout(); if surface?.view.superview === self { surface?.view.frame = bounds } }
}
