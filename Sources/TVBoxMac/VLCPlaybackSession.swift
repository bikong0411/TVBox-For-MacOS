import AppKit
@preconcurrency import VLCKit

/// Each request has its own delegate and player identity. A cancelled input can
/// finish shutting down without delivering events to the next channel.
@MainActor final class VLCPlaybackSession: NSObject, VLCMediaPlayerDelegate {
    let player: VLCMediaPlayer
    var onState: ((VLCMediaPlayerState) -> Void)?
    private static let inputQueue = DispatchQueue(label: "TVBox.VLC.input", qos: .userInitiated)
    private static let library = VLCLibrary(options: ["--ignore-config", "--no-interact", "--no-video-title-show", "--no-osd", "--no-mouse-events", "--no-keyboard-events", "--avcodec-hw=any", "--quiet"])
    private var active = true
    private var started = false
    private var desiredVolume: Int32 = 100
    private var desiredMuted = false
    private var desiredRate: Float = 1
    private var initialPosition: Double
    private var initialPaused: Bool
    private var paused = false
    private var requestedPosition: Double?
    init(url: URL, headers: [String: String], drawable: VLCVideoView, position: Double, paused: Bool, rate: Float, volume: Double, muted: Bool) {
        player = VLCMediaPlayer(library: Self.library)
        initialPosition = position; initialPaused = paused; desiredRate = rate
        self.paused = paused
        desiredVolume = Int32(min(100, max(0, volume * 100))); desiredMuted = muted
        super.init()
        player.drawable = drawable; player.delegate = self
        let media = VLCMedia(url: url)
        media.addOptions(["network-caching": 1000, "file-caching": 300])
        for (key, value) in headers {
            switch key.lowercased() {
            case "user-agent": media.addOptions(["http-user-agent": value])
            case "referer", "referrer": media.addOptions(["http-referrer": value])
            default: break
            }
        }
        player.media = media
        player.audio?.volume = desiredVolume
        player.audio?.isMuted = desiredMuted
    }
    func start() {
        // Order teardown and subsequent starts outside the UI event handler.
        // Each input owns a separate drawable, so asynchronous VLC shutdown
        // cannot remove the next channel's video layer.
        Self.inputQueue.async { [weak self] in
            Task { @MainActor in
                guard let self, self.active else { return }
                self.player.play()
            }
        }
    }
    var position: Double { requestedPosition ?? max(0, Double(player.time.intValue) / 1000) }
    var duration: Double { max(0, Double(player.media?.length.intValue ?? 0) / 1000) }
    var playing: Bool { !paused && started && ![VLCMediaPlayerState.ended, .error, .stopped].contains(player.state) }
    var seekable: Bool { player.isSeekable }
    var effectiveRate: Float { paused ? desiredRate : (player.rate > 0 ? player.rate : desiredRate) }
    func seek(to seconds: Double) {
        guard seconds.isFinite, seekable else { return }
        // VLCKit caches time notifications; paused inputs may not publish the
        // new clock until resumed. Keep the requested cursor for repeat keys.
        requestedPosition = seconds
        player.time = VLCTime(int: Int32(min(Double(Int32.max), max(0, seconds * 1000))))
    }
    func play() { paused = false; player.play(); player.rate = desiredRate }
    func pause() { paused = true; player.pause() }
    func setRate(_ rate: Float) { desiredRate = rate; if !paused { player.rate = rate } }
    func setVolume(_ value: Double) { desiredVolume = Int32(min(100, max(0, value * 100))); player.audio?.volume = desiredVolume }
    func setMuted(_ value: Bool) { desiredMuted = value; player.audio?.isMuted = value }
    func stop() {
        guard active else { return }; active = false; onState = nil; player.delegate = nil
        let old = player
        Self.inputQueue.async { old.stop() }
    }
    nonisolated func mediaPlayerStateChanged(_ notification: Notification) {
        // Read the state when the notification arrives, not after another
        // channel has loaded; the session identity is checked by the owner.
        guard let source = notification.object as? VLCMediaPlayer else { return }
        let state = source.state
        Task { @MainActor [weak self] in
            guard let self, self.active, source === self.player else { return }
            if state == .playing && !self.started {
                self.started = true
                self.player.audio?.volume = self.desiredVolume
                self.player.audio?.isMuted = self.desiredMuted
                self.player.rate = self.desiredRate
                if self.initialPosition > 0 { self.seek(to: self.initialPosition) }
                if self.initialPaused { self.pause() }
            }
            self.onState?(state)
        }
    }
    nonisolated func mediaPlayerTimeChanged(_ notification: Notification) {
        guard let source = notification.object as? VLCMediaPlayer else { return }
        let observed = Double(source.time.intValue) / 1000
        Task { @MainActor [weak self] in
            guard let self, self.active, source === self.player, let target = self.requestedPosition else { return }
            if abs(observed - target) < 1 { self.requestedPosition = nil }
        }
    }
}
