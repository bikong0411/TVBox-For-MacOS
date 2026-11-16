import Foundation
import Combine
import TVBoxCore

struct DLNAPlaybackState: Equatable {
    var position: Double = 0
    var duration: Double = 0
    var playing = false
    var volume: Double?
    var muted: Bool?
    var canPause = false
    var canSeek = false
    var canVolume = false
    var canMute = false
}

@MainActor final class DLNACastingController: ObservableObject {
    @Published private(set) var devices: [DLNADevice] = []
    @Published private(set) var searching = false
    @Published private(set) var selectedDevice: DLNADevice?
    @Published private(set) var connecting = false
    @Published private(set) var connected = false
    @Published private(set) var state = DLNAPlaybackState()
    @Published private(set) var status = ""
    @Published private(set) var error: String?
    @Published private(set) var controlsBusy = false
    var onEnd: (() -> Void)?
    private let client: DLNAClient
    private let discovery = DLNADiscovery()
    private var searchGeneration = UUID()
    private var searchTasks: [URL: Task<Void, Never>] = [:]
    private var udpFinished = false
    private var generation = UUID()
    private var pollTask: Task<Void, Never>?
    private var commandTail: Task<Void, Never>?
    private var volumeTask: Task<Void, Never>?
    private var seekTask: Task<Void, Never>?
    private var relay: CastMediaRelay?
    private var remux: LiveRemuxSession?
    private var activity: NSObjectProtocol?
    private var live = false
    private var ended = false
    private var rejectedActions: Set<String> = []
    private(set) var hasPlayed = false
    private var stateRevision = 0
    init(client: DLNAClient = DLNAClient()) { self.client = client }
    func search() {
        stopSearch(); devices = selectedDevice.map { [$0] } ?? []
        searching = true; udpFinished = false; let token = UUID(); searchGeneration = token
        discovery.search(onLocation: { [weak self] url in
            Task { @MainActor in
                guard let self, self.searchGeneration == token, self.searchTasks[url] == nil else { return }
                self.searchTasks[url] = Task {
                    defer {
                        if self.searchGeneration == token {
                            self.searchTasks.removeValue(forKey: url)
                            if self.udpFinished && self.searchTasks.isEmpty { self.searching = false }
                        }
                    }
                    guard let device = try? await self.client.device(at: url), !Task.isCancelled, self.searchGeneration == token else { return }
                    self.devices.removeAll { $0.id == device.id }; self.devices.append(device)
                    self.devices.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
                }
            }
        }, onFinish: { [weak self] in
            Task { @MainActor in
                guard let self, self.searchGeneration == token else { return }
                self.udpFinished = true; if self.searchTasks.isEmpty { self.searching = false }
            }
        })
    }
    func stopSearch() {
        searchGeneration = UUID(); discovery.stop(); searchTasks.values.forEach { $0.cancel() }
        searchTasks.removeAll(); searching = false
    }
    func connect(to device: DLNADevice, source: URL, headers: [String: String], title: String,
                 position: Double, paused: Bool, isLive: Bool) async throws {
        let previous = disconnect()
        let token = UUID(); generation = token; selectedDevice = device
        connecting = true; connected = false; live = isLive; ended = false; error = nil
        rejectedActions = []; hasPlayed = false
        status = "正在连接电视…"
        var localRelay: CastMediaRelay?
        do {
            await previous.value
            try check(token)
            var source = source
            if isLive && source.pathExtension.lowercased() == "flv" {
                status = "正在准备电视可播放的直播…"
                let session = try LiveRemuxSession(helperURL: LiveRemuxSession.bundledHelperURL)
                remux = session; source = try await session.start(input: source, headers: headers)
                try check(token)
            }
            guard let peer = device.transport.controlURL.host, LANIPv4.isLocal(peer) else {
                throw TVError.message("电视没有提供可访问的局域网地址。")
            }
            let relay = CastMediaRelay(source: source, headers: headers, peer: peer)
            localRelay = relay; self.relay = relay
            let address = try await relay.start(); try check(token)
            status = "正在发送视频到电视…"
            let metadata = DLNAProtocol.metadata(title: title, mediaURL: address, mime: CastMediaRelay.mime(source))
            do {
                try await client.action("SetAVTransportURI", service: device.transport, arguments: [("CurrentURI", address.absoluteString), ("CurrentURIMetaData", metadata)])
            } catch is DLNAFault {
                // Some older renderers accept the URI only with empty DIDL.
                try await client.action("SetAVTransportURI", service: device.transport, arguments: [("CurrentURI", address.absoluteString), ("CurrentURIMetaData", "")])
            }
            try check(token)
            try await client.action("Play", service: device.transport, arguments: [("Speed", "1")])
            status = "正在等待电视开始播放…"
            let deadline = Date().addingTimeInterval(20)
            while Date() < deadline {
                try check(token)
                let info = try await client.action("GetTransportInfo", service: device.transport)
                if info["CurrentTransportStatus"] == "ERROR_OCCURRED" { throw DLNAFault(714) }
                if info["CurrentTransportState"] == "PLAYING" { break }
                try await Task.sleep(nanoseconds: 500_000_000)
            }
            try check(token)
            let info = try await client.action("GetTransportInfo", service: device.transport)
            guard info["CurrentTransportState"] == "PLAYING" else { throw TVError.message("电视没有开始播放。请确认电视已允许投屏，或换一个 MP4 / HLS 视频。") }
            if !isLive && position > 1, device.transport.actions.contains("Seek") {
                _ = try? await client.action("Seek", service: device.transport, arguments: [("Unit", "REL_TIME"), ("Target", DLNAProtocol.time(position))])
            }
            if paused && device.transport.actions.contains("Pause") {
                try await client.action("Pause", service: device.transport)
            }
            try check(token)
            try await refresh(device, token: token)
            try check(token)
            connected = true; hasPlayed = true; connecting = false
            activity = ProcessInfo.processInfo.beginActivity(options: [.idleSystemSleepDisabled], reason: "电视投屏需要持续提供视频")
            pollTask = Task { [weak self] in
                var failures = 0
                while !Task.isCancelled {
                    do { try await Task.sleep(nanoseconds: 1_000_000_000) } catch { return }
                    guard let self, self.generation == token else { return }
                    if self.controlsBusy { continue }
                    do { try await self.refresh(device, token: token); failures = 0 }
                    catch {
                        if Task.isCancelled || self.generation != token { return }
                        failures += 1
                        if failures >= 3 {
                            self.connected = false; self.error = "与电视的连接已断开。可以重新投屏，或返回本机播放。"
                            self.status = "投屏连接已断开"; self.releaseMedia(); return
                        }
                    }
                }
            }
        } catch {
            localRelay?.stop()
            if generation == token {
                connecting = false; connected = false; status = "投屏未能开始"
                self.error = friendly(error); releaseMedia()
                // A failed start must not leave the television unexpectedly playing.
                _ = try? await client.action("Stop", service: device.transport)
            }
            throw error
        }
    }
    private func check(_ token: UUID) throws { try Task.checkCancellation(); if generation != token { throw CancellationError() } }
    private func refresh(_ device: DLNADevice, token: UUID) async throws {
        let revision = stateRevision
        let transport = try await client.action("GetTransportInfo", service: device.transport)
        try check(token)
        if transport["CurrentTransportStatus"] == "ERROR_OCCURRED" { throw DLNAFault(714) }
        var next = state
        let mode = transport["CurrentTransportState"] ?? ""
        next.playing = mode == "PLAYING"
        next.canPause = device.transport.actions.contains("Pause") && !rejectedActions.contains("Pause")
        next.canSeek = !live && device.transport.actions.contains("Seek") && !rejectedActions.contains("Seek")
        if let values = try? await client.action("GetPositionInfo", service: device.transport) {
            next.position = DLNAProtocol.seconds(values["RelTime"]); next.duration = DLNAProtocol.seconds(values["TrackDuration"])
        }
        try check(token)
        if let rendering = device.rendering {
            if rendering.actions.contains("GetVolume") && rendering.actions.contains("SetVolume"),
               let values = try? await client.action("GetVolume", service: rendering, arguments: [("Channel", "Master")]),
               let volume = values["CurrentVolume"].flatMap(Double.init), volume.isFinite {
                next.volume = min(1, max(0, volume / 100)); next.canVolume = true
            } else { next.canVolume = false }
            if rendering.actions.contains("GetMute") && rendering.actions.contains("SetMute"),
               let values = try? await client.action("GetMute", service: rendering, arguments: [("Channel", "Master")]),
               let muted = values["CurrentMute"] {
                next.muted = muted == "1" || muted.lowercased() == "true"; next.canMute = true
            } else { next.canMute = false }
        }
        try check(token)
        guard revision == stateRevision else { return }
        let actions = transport["CurrentTransportState"] == "PLAYING" ? "正在电视上播放" : mode == "PAUSED_PLAYBACK" ? "电视已暂停" : mode == "TRANSITIONING" ? "电视正在缓冲…" : "电视已停止"
        next.canVolume = next.canVolume && !rejectedActions.contains("SetVolume")
        next.canMute = next.canMute && !rejectedActions.contains("SetMute")
        state = next; status = actions
        if mode == "STOPPED", !ended, next.duration > 0, next.position >= next.duration - 1 {
            ended = true; onEnd?()
        }
    }
    func togglePlayback() {
        guard let device = selectedDevice, connected else { return }
        if state.playing {
            guard state.canPause else { error = "电视不支持暂停，请使用电视遥控器或结束投屏。"; return }
            command("Pause", service: device.transport)
        } else { ended = false; command("Play", service: device.transport, arguments: [("Speed", "1")]) }
    }
    func pause() { if state.playing { togglePlayback() } }
    func seek(to seconds: Double) {
        guard let device = selectedDevice, connected, state.canSeek, seconds.isFinite, state.duration > 0 else { return }
        let target = min(state.duration, max(0, seconds)); stateRevision += 1; state.position = target
        seekTask?.cancel(); let token = generation
        seekTask = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: 120_000_000) } catch { return }
            guard let self, self.generation == token else { return }
            self.command("Seek", service: device.transport, arguments: [("Unit", "REL_TIME"), ("Target", DLNAProtocol.time(target))])
        }
    }
    func setVolume(_ value: Double) {
        guard let device = selectedDevice, let rendering = device.rendering, connected, state.canVolume, value.isFinite else { return }
        let target = min(1, max(0, value)); stateRevision += 1; state.volume = target
        volumeTask?.cancel(); let token = generation
        volumeTask = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: 150_000_000) } catch { return }
            guard let self, self.generation == token else { return }
            self.command("SetVolume", service: rendering, arguments: [("Channel", "Master"), ("DesiredVolume", String(Int((target * 100).rounded())))])
        }
    }
    func toggleMute() {
        guard let rendering = selectedDevice?.rendering, connected, state.canMute else { return }
        let muted = !(state.muted ?? false); stateRevision += 1; state.muted = muted
        command("SetMute", service: rendering, arguments: [("Channel", "Master"), ("DesiredMute", muted ? "1" : "0")])
    }
    private func command(_ action: String, service: DLNAService, arguments: [(String, String)] = []) {
        let previous = commandTail, token = generation
        commandTail = Task { [weak self] in
            await previous?.value
            guard let self, self.generation == token, let device = self.selectedDevice else { return }
            self.controlsBusy = true; self.stateRevision += 1
            defer { if self.generation == token { self.controlsBusy = false } }
            do {
                try self.check(token)
                try await self.client.action(action, service: service, arguments: arguments)
                try await self.refresh(device, token: token); self.error = nil
            } catch {
                guard self.generation == token, !Task.isCancelled else { return }
                self.error = self.friendly(error)
                if let fault = error as? DLNAFault, [401, 602, 710].contains(fault.code) {
                    self.rejectedActions.insert(action)
                    switch action {
                    case "Seek": self.state.canSeek = false
                    case "Pause": self.state.canPause = false
                    case "SetVolume": self.state.canVolume = false
                    case "SetMute": self.state.canMute = false
                    default: break
                    }
                }
            }
        }
    }
    @discardableResult func disconnect() -> Task<Void, Never> {
        let old = selectedDevice, previous = commandTail
        // Keep the command chain alive until its final Stop is acknowledged.
        // Generation checks discard queued controls; cancelling this tail could
        // otherwise cancel the Stop itself when immediately casting again.
        generation = UUID(); pollTask?.cancel(); pollTask = nil
        volumeTask?.cancel(); seekTask?.cancel(); selectedDevice = nil
        connected = false; connecting = false; controlsBusy = false; state = DLNAPlaybackState(); status = ""; error = nil
        releaseMedia()
        let task = Task { [client] in await previous?.value; if let old { _ = try? await client.action("Stop", service: old.transport) } }
        commandTail = task; return task
    }
    private func releaseMedia() {
        relay?.stop(); relay = nil; remux?.stop(); remux = nil
        if let activity { ProcessInfo.processInfo.endActivity(activity); self.activity = nil }
    }
    private func friendly(_ error: Error) -> String {
        if error is DLNAFault || error is TVError { return error.localizedDescription }
        return "暂时无法连接电视。请确认电视已开启 DLNA、与 Mac 连接同一网络，并允许本应用访问局域网。"
    }
}
