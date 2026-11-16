import AppKit
import OpenGL.GL3
import MPVBridge
import TVBoxCore

private final class MPVDisplaySignal: @unchecked Sendable {
    private let lock = NSLock()
    private var queued = false
    weak var view: MPVRenderingView?
    func signal() {
        lock.lock(); if queued { lock.unlock(); return }; queued = true; lock.unlock()
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }; self.lock.lock(); self.queued = false; self.lock.unlock()
            self.view?.needsDisplay = true
        }
    }
}

final class MPVRenderingView: NSOpenGLView {
    private var core: OpaquePointer?
    private let signal = MPVDisplaySignal()
    private(set) var framesRendered = 0
    init?(core: OpaquePointer) throws {
        let attributes: [NSOpenGLPixelFormatAttribute] = [UInt32(NSOpenGLPFAOpenGLProfile), UInt32(NSOpenGLProfileVersion3_2Core), UInt32(NSOpenGLPFADoubleBuffer), UInt32(NSOpenGLPFAAccelerated), UInt32(NSOpenGLPFAAllowOfflineRenderers), 0]
        guard let format = NSOpenGLPixelFormat(attributes: attributes) else { throw TVError.message("无法创建视频渲染环境。") }
        super.init(frame: .zero, pixelFormat: format)
        wantsBestResolutionOpenGLSurface = true; self.core = core; signal.view = self
        openGLContext?.makeCurrentContext()
        var interval: GLint = 1; openGLContext?.setValues(&interval, for: .swapInterval)
        guard tvmpv_render_init(core) >= 0 else { self.core = nil; throw TVError.message("IINA 组件无法创建内嵌视频画面。") }
        tvmpv_render_callback(core, { raw in
            if let raw { Unmanaged<MPVDisplaySignal>.fromOpaque(raw).takeUnretainedValue().signal() }
        }, Unmanaged.passUnretained(signal).toOpaque())
    }
    required init?(coder: NSCoder) { nil }
    override func draw(_ dirtyRect: NSRect) {
        guard let core, !isHidden else { return }
        openGLContext?.makeCurrentContext()
        let pixels = convertToBacking(bounds)
        tvmpv_render(core, Int32(pixels.width.rounded()), Int32(pixels.height.rounded()))
        openGLContext?.flushBuffer(); framesRendered += 1
    }
    override func reshape() { super.reshape(); openGLContext?.update(); needsDisplay = true }
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); openGLContext?.update(); needsDisplay = true }
    func shutdown() {
        guard let core else { return }; self.core = nil
        openGLContext?.makeCurrentContext(); tvmpv_render_free(core); removeFromSuperview()
    }
}

struct MPVSnapshot: Sendable {
    var position: Double = 0, duration: Double = 0, rate: Float = 1
    var paused = false, seekable = false, buffering = false, ready = false, ended = false
    var failure: Int32 = 0
}

/// Client API calls and teardown never block the OpenGL render thread.
private final class MPVWorker: @unchecked Sendable {
    let core: OpaquePointer
    let queue = DispatchQueue(label: "TVBox.mpv.client", qos: .userInitiated)
    private var timer: DispatchSourceTimer?
    private var stopped = false
    private var ended = false
    private var commandFailure: Int32 = 0
    private var loaded = false
    var callback: (@Sendable (MPVSnapshot) -> Void)?
    init(core: OpaquePointer) { self.core = core }
    func start(url: URL) {
        queue.async {
            guard !self.stopped else { return }
            self.command(["loadfile", url.isFileURL ? url.path : url.absoluteString, "replace"])
            let timer = DispatchSource.makeTimerSource(queue: self.queue)
            timer.schedule(deadline: .now(), repeating: .milliseconds(100), leeway: .milliseconds(15))
            timer.setEventHandler { [weak self] in self?.poll() }
            self.timer = timer; timer.resume()
        }
    }
    private func command(_ arguments: [String]) {
        if arguments.first == "seek" { ended = false }
        let strings = arguments.map { strdup($0) }; defer { strings.forEach { free($0) } }
        let pointers: [UnsafePointer<CChar>?] = strings.map { $0.map { UnsafePointer<CChar>($0) } } + [nil]
        let result = pointers.withUnsafeBufferPointer { tvmpv_command(core, $0.baseAddress) }
        if arguments.first == "loadfile", result < 0 { commandFailure = result }
    }
    func send(_ arguments: [String]) { queue.async { if !self.stopped { self.command(arguments) } } }
    func number(_ key: String, _ value: Double) { queue.async { if !self.stopped { _ = tvmpv_set_number(self.core, key, value) } } }
    func flag(_ key: String, _ value: Bool) { queue.async { if !self.stopped { _ = tvmpv_set_flag(self.core, key, value ? 1 : 0) } } }
    private func poll() {
        guard !stopped else { return }
        var error: Int32 = 0, reason: Int32 = -1, failure = commandFailure
        commandFailure = 0
        for _ in 0..<64 {
            let event = tvmpv_event(core, &error, &reason)
            if event == 0 { break }
            if event == 7 && reason == 4 { failure = error }
            if event == 8 { loaded = true }
            if event == 5 && error < 0 && !loaded { failure = error }
            if event == 7 && reason == 0 { ended = true }
        }
        var s = MPVSnapshot()
        s.position = max(0, tvmpv_number(core, "time-pos", 0)); s.duration = max(0, tvmpv_number(core, "duration", 0))
        s.rate = Float(tvmpv_number(core, "speed", 1)); s.paused = tvmpv_flag(core, "pause", 0) == 1
        s.seekable = tvmpv_flag(core, "seekable", 0) == 1; s.buffering = tvmpv_flag(core, "paused-for-cache", 0) == 1
        s.ready = tvmpv_number(core, "width", 0) > 0 || tvmpv_number(core, "audio-params/samplerate", 0) > 0
        s.ended = ended || tvmpv_flag(core, "eof-reached", 0) == 1; s.failure = failure; callback?(s)
    }
    func stop() {
        queue.async {
            guard !self.stopped else { return }; self.stopped = true
            self.timer?.cancel(); self.timer = nil; self.callback = nil; tvmpv_destroy(self.core)
        }
    }
}

/// Own a newly initialized core across the background-to-main handoff. A
/// cancelled request still destroys its core without blocking the UI thread.
private final class MPVPreparedCore: @unchecked Sendable {
    private(set) var core: OpaquePointer?
    private static let cleanup = DispatchQueue(label: "TVBox.mpv.bootstrap-cleanup", qos: .utility)
    private init(_ core: OpaquePointer) { self.core = core }
    func take() -> OpaquePointer { let value = core!; core = nil; return value }
    deinit { if let core { Self.cleanup.async { tvmpv_destroy(core) } } }
    static func prepare(url: URL, headers: [String: String], position: Double, paused: Bool, rate: Float, volume: Double, muted: Bool) throws -> MPVPreparedCore {
        guard let core = tvmpv_create() else { throw TVError.message("无法启动 IINA 播放组件。") }
        var initialized = false
        defer { if !initialized { tvmpv_destroy(core) } }
        for (key, value) in ["config": "no", "load-scripts": "no", "terminal": "no", "msg-level": "all=no", "vo": "libmpv", "hwdec": "auto-safe", "vd-lavc-dr": "no", "input-default-bindings": "no", "input-vo-keyboard": "no", "osc": "no", "ytdl": "no", "keep-open": "yes", "video-timing-offset": "0", "resume-playback": "no", "network-timeout": "10"] { _ = tvmpv_option(core, key, value) }
        if ["127.0.0.1", "localhost", "::1"].contains(url.host?.lowercased() ?? "") {
            // A shell proxy must never intercept our private loopback relay.
            _ = tvmpv_option(core, "stream-lavf-o", "http_proxy=")
        }
        guard headers.allSatisfy({ $0.key.rangeOfCharacter(from: .newlines) == nil && $0.value.rangeOfCharacter(from: .newlines) == nil }) else { throw TVError.message("片源请求头格式不正确。") }
        let sorted = headers.sorted { $0.key < $1.key }
        let names = sorted.map { strdup($0.key) }, values = sorted.map { strdup($0.value) }
        defer { names.forEach { free($0) }; values.forEach { free($0) } }
        let n: [UnsafePointer<CChar>?] = names.map { $0.map { UnsafePointer<CChar>($0) } }
        let v: [UnsafePointer<CChar>?] = values.map { $0.map { UnsafePointer<CChar>($0) } }
        let result = n.withUnsafeBufferPointer { names in v.withUnsafeBufferPointer { values in tvmpv_headers(core, names.baseAddress, values.baseAddress, Int32(sorted.count)) } }
        guard result >= 0 else { throw TVError.message("IINA 组件无法设置片源请求头。") }
        _ = tvmpv_option(core, "start", String(max(0, position.isFinite ? position : 0)))
        _ = tvmpv_option(core, "pause", paused ? "yes" : "no"); _ = tvmpv_option(core, "speed", String(rate))
        _ = tvmpv_option(core, "volume", String(min(100, max(0, volume * 100)))); _ = tvmpv_option(core, "mute", muted ? "yes" : "no")
        guard tvmpv_initialize(core) >= 0 else { throw TVError.message("IINA 播放组件初始化失败。") }
        initialized = true
        return MPVPreparedCore(core)
    }
}

@MainActor final class MPVPlaybackSession {
    let renderingView: MPVRenderingView
    var onUpdate: ((MPVSnapshot) -> Void)?
    private let worker: MPVWorker
    private let url: URL
    private var active = true
    private var snapshot = MPVSnapshot()
    private var requestedPosition: (Double, Date)?
    private var desiredPaused: Bool
    static func make(url: URL, headers: [String: String], position: Double, paused: Bool, rate: Float, volume: Double, muted: Bool) async throws -> MPVPlaybackSession {
        try await MPVLibrary.load()
        try Task.checkCancellation()
        let prepared = try await Task.detached(priority: .userInitiated) {
            try MPVPreparedCore.prepare(url: url, headers: headers, position: position, paused: paused, rate: rate, volume: volume, muted: muted)
        }.value
        try Task.checkCancellation()
        return try MPVPlaybackSession(prepared: prepared, url: url, paused: paused, rate: rate)
    }
    private init(prepared: MPVPreparedCore, url: URL, paused: Bool, rate: Float) throws {
        let core = prepared.core!
        guard let view = try MPVRenderingView(core: core) else { throw TVError.message("无法创建内嵌视频视图。") }
        renderingView = view
        worker = MPVWorker(core: prepared.take()); self.url = url; desiredPaused = paused
        snapshot.rate = rate; snapshot.paused = paused
        worker.callback = { [weak self] value in
            Task { @MainActor in
                guard let self, self.active else { return }; self.snapshot = value
                if let (target, at) = self.requestedPosition, abs(value.position - target) < 0.8 || Date().timeIntervalSince(at) > 3 { self.requestedPosition = nil }
                self.onUpdate?(value)
            }
        }
    }
    var position: Double { requestedPosition?.0 ?? snapshot.position }
    var duration: Double { snapshot.duration.isFinite ? snapshot.duration : 0 }
    var playing: Bool { !desiredPaused && snapshot.ready && !snapshot.ended }
    var seekable: Bool { snapshot.seekable }
    var effectiveRate: Float { snapshot.rate }
    var reachedEnd: Bool { snapshot.ended }
    func start() { worker.start(url: url) }
    func play() { desiredPaused = false; worker.flag("pause", false) }
    func pause() { desiredPaused = true; worker.flag("pause", true) }
    func seek(to value: Double) { guard value.isFinite else { return }; requestedPosition = (value, Date()); worker.send(["seek", String(value), "absolute+exact"]) }
    func setRate(_ value: Float) { worker.number("speed", Double(value)); snapshot.rate = value }
    func setVolume(_ value: Double) { worker.number("volume", value * 100) }
    func setMuted(_ value: Bool) { worker.flag("mute", value) }
    func stop() { guard active else { return }; active = false; onUpdate = nil; renderingView.shutdown(); worker.stop() }
    deinit { let view = renderingView, worker = worker; Task { @MainActor in view.shutdown(); worker.stop() } }
}
