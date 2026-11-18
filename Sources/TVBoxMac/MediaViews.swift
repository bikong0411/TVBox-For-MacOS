import SwiftUI
import AVKit
import TVBoxCore

struct DetailView: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.dismiss) var dismiss
    let selection: DetailSelection
    @State private var video: Video
    @State private var loading = false
    @State private var error: String?
    @State private var lineID = ""
    init(selection: DetailSelection) { self.selection = selection; _video = State(initialValue: selection.video) }
    var line: PlayLine? { video.lines.first { $0.id == lineID } ?? video.lines.first }
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack { Text(L10n.text("影片详情")).font(.system(size: 12)).foregroundStyle(Theme.muted); Spacer(); Button { dismiss() } label: { Image(systemName: "xmark.circle.fill").font(.system(size: 20)).foregroundStyle(Theme.muted) }.buttonStyle(.plain).keyboardShortcut(.cancelAction) }.padding(24)
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    HStack(alignment: .top, spacing: 25) {
                        PosterView(video: video).frame(width: 165, height: 235).clipShape(RoundedRectangle(cornerRadius: 11))
                        VStack(alignment: .leading, spacing: 13) {
                            Text(video.title).font(.system(size: 27, weight: .semibold)).textSelection(.enabled)
                            Text([video.year, video.area, video.note].filter { !$0.isEmpty }.joined(separator: " · ")).font(.system(size: 12)).foregroundStyle(Theme.muted)
                            if !video.director.isEmpty { Text(L10n.text("导演  \(video.director)")).font(.system(size: 12)).foregroundStyle(Theme.muted) }
                            if !video.actor.isEmpty { Text(L10n.text("主演  \(video.actor)")).font(.system(size: 12)).foregroundStyle(Theme.muted).lineLimit(3) }
                            Text(selection.site?.name ?? L10n.text("开放电影 / 视频直链")).font(.system(size: 10)).foregroundStyle(Theme.accent)
                            HStack(spacing: 12) {
                                Button { start() } label: { Label(selection.resume == nil ? L10n.text("立即播放") : L10n.text("继续播放"), systemImage: "play.fill") }.buttonStyle(.borderedProminent).disabled(line == nil || loading)
                                Button { store.toggleFavorite(video, site: selection.site) } label: { Image(systemName: store.isFavorite(video, site: selection.site) ? "heart.fill" : "heart") }.buttonStyle(.bordered).help(L10n.text("收藏影片"))
                            }.padding(.top, 7)
                            if let resume = selection.resume, resume.position > 0 { Text(L10n.text("上次看到 \(resume.episode?.name ?? "") · \(formatTime(resume.position))")).font(.system(size: 10)).foregroundStyle(Theme.muted) }
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }
                    if loading { ProgressView(L10n.text("正在获取剧集…")).frame(maxWidth: .infinity) }
                    if let error { ErrorBanner(message: error) { Task { await load() } } }
                    if !video.summary.isEmpty {
                        VStack(alignment: .leading, spacing: 10) { Text(L10n.text("剧情简介")).font(.system(size: 14, weight: .semibold)); Text(video.summary).font(.system(size: 12)).lineSpacing(6).foregroundStyle(Theme.muted).textSelection(.enabled) }
                    }
                    if !video.lines.isEmpty {
                        HStack { Text(L10n.text("选集播放")).font(.system(size: 15, weight: .semibold)); Spacer(); Text(L10n.text("\(line?.episodes.count ?? 0) 集")).font(.system(size: 11)).foregroundStyle(Theme.muted) }
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack {
                                ForEach(video.lines) { item in
                                    Button { lineID = item.id } label: { Text(item.name).font(.system(size: 12)).padding(.horizontal, 15).padding(.vertical, 8).foregroundStyle(line?.id == item.id ? Theme.accent : Theme.muted).background(line?.id == item.id ? Theme.accent.opacity(0.1) : Theme.panel, in: Capsule()) }.buttonStyle(.plain)
                                }
                            }
                        }
                        if let line {
                            LazyVGrid(columns: [GridItem(.adaptive(minimum: 100), spacing: 9)], spacing: 9) {
                                ForEach(Array(line.episodes.enumerated()), id: \.offset) { index, episode in
                                    Button { store.play(video: video, site: selection.site, line: line, index: index) } label: { Text(episode.name).font(.system(size: 12)).lineLimit(1).frame(maxWidth: .infinity).padding(.vertical, 11).background(Theme.panel, in: RoundedRectangle(cornerRadius: 7)) }.buttonStyle(.plain)
                                }
                            }
                        }
                    } else if !loading && error == nil { Text(L10n.text("这个接口没有返回可播放的剧集地址。")).font(.system(size: 12)).foregroundStyle(Theme.muted) }
                }.padding(.horizontal, 28).padding(.bottom, 28)
            }
        }.frame(width: 740, height: 650).background(Theme.background).tint(Theme.accent)
            .task { await load() }
    }
    private func load() async {
        guard let site = selection.site, video.lines.isEmpty else { return }
        loading = true; error = nil
        do { let result = try await store.service.detail(video: video, site: site); if !Task.isCancelled { video = result } }
        catch { if !Task.isCancelled { self.error = error.localizedDescription } }
        loading = false
    }
    private func start() {
        if let resume = selection.resume, let episode = resume.episode {
            for line in video.lines {
                if let index = line.episodes.firstIndex(where: { $0.url == episode.url }) { store.play(video: video, site: selection.site, line: line, index: index, position: resume.position); return }
            }
        }
        if let line { store.play(video: video, site: selection.site, line: line, index: 0) }
    }
}

struct NativePlayerView: NSViewRepresentable {
    let surface: PersistentVideoSurface
    var isFullscreen = false
    var onSeek: (Double) -> Bool = { _ in false }
    var onToggleFullscreen: () -> Void = {}
    func makeCoordinator() -> Coordinator { Coordinator(onToggleFullscreen: onToggleFullscreen, onSeek: onSeek) }
    func makeNSView(context: Context) -> VideoHostView {
        let view = VideoHostView(surface: surface, isFullscreen: isFullscreen); surface.attach(to: view)
        view.onToggleFullscreen = onToggleFullscreen
        context.coordinator.installShortcut(on: view)
        return view
    }
    func updateNSView(_ view: VideoHostView, context: Context) {
        surface.attach(to: view); view.onToggleFullscreen = onToggleFullscreen; context.coordinator.onToggleFullscreen = onToggleFullscreen
        context.coordinator.onSeek = onSeek
    }
    static func dismantleNSView(_ view: VideoHostView, coordinator: Coordinator) { coordinator.invalidate(); view.onToggleFullscreen = nil; view.surface?.detach(from: view) }
    final class Coordinator: NSObject {
        var onToggleFullscreen: () -> Void
        var onSeek: (Double) -> Bool
        private weak var playerView: NSView?
        private var keyMonitor: Any?
        init(onToggleFullscreen: @escaping () -> Void, onSeek: @escaping (Double) -> Bool) { self.onToggleFullscreen = onToggleFullscreen; self.onSeek = onSeek }
        static func isFullscreenShortcut(_ event: NSEvent) -> Bool {
            event.type == .keyDown && event.charactersIgnoringModifiers?.lowercased() == "f" &&
                event.modifierFlags.intersection([.command, .control, .option, .shift]) == [.command, .control]
        }
        static func seekOffset(for event: NSEvent) -> Double? {
            guard event.type == .keyDown, event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty else { return nil }
            switch event.keyCode { case 123: return -3; case 124: return 3; default: return nil }
        }
        static func preservesArrowKeys(for responder: NSResponder?) -> Bool {
            var current = responder, visited = Set<ObjectIdentifier>()
            while let value = current, visited.count < 16, visited.insert(ObjectIdentifier(value)).inserted {
                if value is NSTextView || value is NSControl || value is NSTableView { return true }
                current = value.nextResponder
            }
            return false
        }
        func installShortcut(on view: NSView) {
            playerView = view
            keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self, let window = self.playerView?.window, event.window === window else { return event }
                if Self.isFullscreenShortcut(event) {
                    if !event.isARepeat { self.onToggleFullscreen() }; return nil
                }
                guard let offset = Self.seekOffset(for: event), NSApp.keyWindow === window,
                      NSApp.modalWindow == nil, RunLoop.current.currentMode != .eventTracking,
                      !Self.preservesArrowKeys(for: window.firstResponder), self.onSeek(offset) else { return event }
                return nil
            }
        }
        func invalidate() {
            if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }; keyMonitor = nil; playerView = nil; onToggleFullscreen = {}; onSeek = { _ in false }
        }
        deinit { if let keyMonitor { NSEvent.removeMonitor(keyMonitor) } }

    }
}

struct PlaybackView: View {
    @EnvironmentObject var store: AppStore
    var body: some View {
        PlayerContent(controller: store.player, fullscreen: store.fullscreen)
    }
}

private struct PlayerContent: View {
    @EnvironmentObject var store: AppStore
    @ObservedObject var controller: PlayerController
    @ObservedObject var fullscreen: PlaybackFullscreenPresenter
    var body: some View {
        if let current = store.playback {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    HStack {
                        Button { store.stop() } label: { Label(L10n.text("返回片库"), systemImage: "chevron.left") }.buttonStyle(.plain).foregroundStyle(Theme.muted)
                        Spacer()
                        Button { fullscreen.toggle(store: store) } label: { Label(fullscreen.isPresented ? L10n.text("返回窗口") : L10n.text("全屏"), systemImage: "arrow.up.left.and.arrow.down.right") }.buttonStyle(.plain).help(L10n.text("双击画面或按 Control + Command + F 切换全屏"))
                        if current.isLive { Label(current.catchupProgramme == nil ? "LIVE" : L10n.text("回看"), systemImage: current.catchupProgramme == nil ? "dot.radiowaves.left.and.right" : "clock.arrow.circlepath").font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.accent) }
                    }.font(.system(size: 12))
                    PlaybackSurface(controller: controller, fullscreen: fullscreen).aspectRatio(16 / 9, contentMode: .fit).clipShape(RoundedRectangle(cornerRadius: 12))
                    ViewThatFits(in: .horizontal) {
                        HStack(alignment: .top, spacing: 20) {
                            playbackTitle(current)
                            Spacer(minLength: 0)
                            PlaybackActions(controller: controller, current: current).fixedSize()
                        }
                        VStack(alignment: .leading, spacing: 14) {
                            playbackTitle(current)
                            ScrollView(.horizontal) { PlaybackActions(controller: controller, current: current) }.scrollIndicators(.hidden)
                        }
                    }
                    if current.line.episodes.count > 1 {
                        HStack { Text(current.isLive ? L10n.text("切换线路") : L10n.text("剧集")).font(.system(size: 15, weight: .semibold)); Spacer(); if !current.isLive { Button(L10n.text("下一集")) { store.nextEpisode() }.disabled(current.index + 1 >= current.line.episodes.count) } }
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 95), spacing: 9)], spacing: 9) {
                            ForEach(Array(current.line.episodes.enumerated()), id: \.offset) { index, episode in
                                Button { store.play(video: current.video, site: current.site, line: current.line, index: index, headers: current.headers, live: current.isLive) } label: {
                                    Text(episode.name).font(.system(size: 12)).lineLimit(1).padding(.vertical, 11).frame(maxWidth: .infinity).foregroundStyle(index == current.index ? Theme.accent : Theme.muted).background(index == current.index ? Theme.accent.opacity(0.1) : Theme.panel, in: RoundedRectangle(cornerRadius: 7))
                                }.buttonStyle(.plain)
                            }
                        }
                    }
                    if current.video.lines.count > 1 {
                        Picker(L10n.text("播放线路"), selection: Binding(get: { current.line.id }, set: { id in
                            if let line = current.video.lines.first(where: { $0.id == id }) { store.play(video: current.video, site: current.site, line: line, index: min(current.index, line.episodes.count - 1)) }
                        })) { ForEach(current.video.lines) { Text($0.name).tag($0.id) } }.frame(maxWidth: 260)
                    }
                    Text(current.isLive && current.catchupProgramme == nil ? L10n.text("双击切换全屏 · Esc 返回") : L10n.text("← 后退 3 秒 · → 快进 3 秒 · 连按 / 长按连续调整 · 双击切换全屏")).font(.system(size: 10)).foregroundStyle(Theme.muted)
                }.padding(30)
            }
        }
    }

    private func playbackTitle(_ current: Playback) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(current.video.title).font(.system(size: 23, weight: .semibold)).lineLimit(2)
            Text("\(current.line.name) · \(current.episode.name)").font(.system(size: 12)).foregroundStyle(Theme.muted)
        }
    }
}

struct PlaybackActions: View {
    @EnvironmentObject var store: AppStore
    @ObservedObject var controller: PlayerController
    let current: Playback

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            if current.isLive {
                if current.catchupProgramme != nil, let channel = store.playingChannel {
                    Button { store.playChannel(channel) } label: { Text(L10n.text("返回直播")).playbackActionLabel() }
                }
                if current.line.episodes.count > 1 {
                    Button { store.nextLiveRoute() } label: { Text(L10n.text("下一条线路")).playbackActionLabel() }
                }
                Button { store.switchChannel(-1) } label: { Text(L10n.text("上一台")).playbackActionLabel() }.disabled(!store.canSwitchChannel(-1))
                Button { store.switchChannel(1) } label: { Text(L10n.text("下一台")).playbackActionLabel() }.disabled(!store.canSwitchChannel(1))
            }
            Text(controller.playbackEngine).font(.system(size: 10)).foregroundStyle(Theme.muted)
                .frame(height: 32).padding(.horizontal, 4)
            PlaybackRateMenu(controller: controller, casting: controller.dlna)
            Button { store.toggleFavorite(current.video, site: current.site) } label: {
                Image(systemName: store.isFavorite(current.video, site: current.site) ? "heart.fill" : "heart")
                    .font(.system(size: 16)).playbackActionLabel(width: 40)
            }.disabled(current.isLive).help(L10n.text("收藏"))
            Menu {
                Button(L10n.text("使用内置 VLC")) { store.useBuiltInPlayback() }
                Button(L10n.text("使用 IINA 播放组件")) { store.useIINAPlayback() }
                Divider()
                Button(L10n.text("复制播放地址")) { store.copyURL() }
            } label: { Image(systemName: "ellipsis") }
            .menuStyle(.borderlessButton).menuIndicator(.visible)
            .frame(width: 34).playbackActionLabel(width: 58).help(L10n.text("更多播放选项"))
        }.buttonStyle(.plain).fixedSize(horizontal: true, vertical: true)
    }
}

private struct PlaybackActionLabel: ViewModifier {
    @Environment(\.isEnabled) private var isEnabled
    var width: CGFloat?
    func body(content: Content) -> some View {
        content.font(.system(size: 12, weight: .medium))
            .padding(.horizontal, width == nil ? 12 : 0)
            .frame(width: width, height: 32, alignment: .center)
            .foregroundStyle(Theme.accent.opacity(isEnabled ? 1 : 0.35))
            .background(Theme.accent.opacity(isEnabled ? 0.06 : 0.025), in: RoundedRectangle(cornerRadius: 8))
            .contentShape(RoundedRectangle(cornerRadius: 8))
    }
}

extension View {
    func playbackActionLabel(width: CGFloat? = nil) -> some View { modifier(PlaybackActionLabel(width: width)) }
}


struct PlaybackSurface: View {
    @EnvironmentObject var store: AppStore
    @ObservedObject var controller: PlayerController
    @ObservedObject var fullscreen: PlaybackFullscreenPresenter
    var isFullscreen = false
    var body: some View {
        if let current = store.playback {
            ZStack {
                Color.black
                let isActiveSurface = !fullscreen.isPresented || isFullscreen
                if isActiveSurface, let authorization = controller.playbackAuthorization {
                    PlaybackAuthorizationPrompt(
                        authorization: authorization,
                        sourceName: current.site?.name ?? current.line.name,
                        retry: { store.retryPlayback() },
                        dismiss: { controller.playbackAuthorization = nil }
                    )
                } else if isActiveSurface {
                NativePlayerView(surface: controller.videoSurface, isFullscreen: isFullscreen, onSeek: { offset in
                    guard (!current.isLive || current.catchupProgramme != nil), controller.seekRelative(by: offset) else { return false }
                    NotificationCenter.default.post(name: .playerSurfacePointerActivity, object: controller.videoSurface)
                    return true
                }) { fullscreen.toggle(store: store) }
                AirPlayPlaybackStatus(controller: controller)
                DLNAPlaybackStatus(controller: controller, casting: controller.dlna)
                if let error = controller.error {
                    VStack(spacing: 15) {
                        Image(systemName: "exclamationmark.circle").font(.system(size: 35)).foregroundStyle(Theme.accent)
                        Text(controller.failure?.title ?? L10n.text("暂时无法播放")).font(.system(size: 18, weight: .semibold))
                        Text(error).font(.system(size: 12)).foregroundStyle(Theme.muted).multilineTextAlignment(.center).frame(maxWidth: 420)
                        HStack {
                            Button(current.isLive && current.line.episodes.count > 1 ? L10n.text("重试全部线路") : L10n.text("重试")) { store.retryPlayback() }
                            if current.isLive && current.line.episodes.count > 1 { Button(L10n.text("下一条线路")) { store.nextLiveRoute() } }
                            Button(L10n.text("复制地址")) { store.copyURL() }
                        }
                        if current.isLive {
                            Button(L10n.text("刷新直播列表")) { store.stop(); store.section = .live; store.refreshLive() }.font(.system(size: 12))
                        }
                        if let failure = controller.failure, !failure.diagnostic.isEmpty {
                            DisclosureGroup(L10n.text("错误详情")) {
                                Text(failure.diagnostic).font(.system(size: 10, design: .monospaced)).foregroundStyle(Theme.muted).textSelection(.enabled).padding(.top, 7)
                            }.font(.system(size: 11)).foregroundStyle(Theme.muted).frame(maxWidth: 420)
                        }
                        Button(L10n.text("用公开演示视频检查播放器")) {
                            if let video = Demo.videos.first, let line = video.lines.first { store.play(video: video, site: nil, line: line, index: 0) }
                        }.font(.system(size: 11)).buttonStyle(.plain).foregroundStyle(Theme.accent)
                    }.padding(28).frame(maxWidth: .infinity, maxHeight: .infinity).background(.black.opacity(0.85))
                } else if !controller.ready { PlaybackConnectionStatus(controller: controller) { store.stop() } }
                if controller.ready && controller.buffering && controller.dlna.selectedDevice == nil {
                    VStack { HStack { Spacer(); ProgressView(L10n.text("正在缓冲…")).controlSize(.small).padding(10).background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 8)) }; Spacer() }.padding(14).allowsHitTesting(false)
                }
                VStack {
                    Spacer(minLength: 0)
                    PlaybackTransportControls(controller: controller, surface: controller.videoSurface, live: current.isLive && current.catchupProgramme == nil, isFullscreen: isFullscreen) { fullscreen.toggle(store: store) }
                }
                if current.isLive { LiveChannelOverlay(browser: store.liveBrowser).environmentObject(store) }
                } else {
                    Button { fullscreen.close() } label: { Label(L10n.text("正在全屏播放 · 返回窗口"), systemImage: "arrow.down.right.and.arrow.up.left").foregroundStyle(Theme.muted) }.buttonStyle(.plain)
                }
            }
        }
    }
}

struct LiveView: View {
    @EnvironmentObject var store: AppStore
    @ObservedObject var browser: LiveBrowserState
    @ObservedObject var probe: NetworkProbeModel
    @State private var visibleSections: [ChannelSection] = []
    @State private var restorePending = true
    private var groups: [String] { store.channelIndex.groups(for: browser.grouping) }
    private var filterKey: LiveFilterKey { LiveFilterKey(revision: store.channelRevision, group: browser.group, query: browser.query, grouping: browser.grouping) }
    var body: some View {
        ScrollViewReader { proxy in
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                HStack {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(L10n.text("打开电视，放松一下。")).font(.system(size: 27, weight: .semibold))
                        Text(L10n.text("\(store.channels.count) 个频道 · \(store.channelIndex.routeCount) 条线路")).font(.system(size: 12)).foregroundStyle(Theme.muted)
                    }
                    Spacer()
                    Button { store.refreshLive() } label: { Image(systemName: "arrow.clockwise") }.disabled(store.liveLoading)
                    Button(L10n.text("添加直播源")) { store.showImport(.live) }.buttonStyle(.borderedProminent)
                }
                HStack(spacing: 12) {
                    if !store.liveSources.isEmpty {
                        Label(L10n.text("直播源"), systemImage: "antenna.radiowaves.left.and.right").font(.system(size: 12)).foregroundStyle(Theme.muted)
                        Picker(L10n.text("直播源"), selection: Binding(get: { store.sourceLibrary.selectedLiveID ?? "" }, set: { store.selectLiveSource($0) })) {
                            ForEach(probe.orderedLiveSources(store.liveSources, byLatency: browser.sourceSort == .latency)) { source in
                                Text(sourceName(source)).tag(source.id)
                            }
                        }.labelsHidden().frame(maxWidth: 360).help(L10n.text("直播源排序：\(browser.sourceSort.title)，可在配置管理中切换"))
                    }
                    Spacer()
                    Picker(L10n.text("直播展示方式"), selection: $browser.layout) {
                        ForEach(LiveLayout.allCases) { layout in Label(layout.title, systemImage: layout.icon).tag(layout) }
                    }.pickerStyle(.segmented).labelsHidden().frame(width: 166).help(L10n.text("切换直播频道的展示方式"))
                }
                if let error = store.liveError { ErrorBanner(message: error) { store.refreshLive() } }
                if store.liveLoading { ProgressView(L10n.text("正在加载直播列表…")).padding() }
                if store.channels.isEmpty && !store.liveLoading {
                    if store.selectedLiveSource?.subscriptions.isEmpty == false {
                        EmptyViewCard(icon: "folder", title: L10n.text("请选择一个子配置"), message: L10n.text("这个直播源包含多个配置地址，可以在配置管理中添加并选择。"), action: L10n.text("查看子配置")) { store.section = .sources }
                    } else {
                        EmptyViewCard(icon: "tv", title: L10n.text("把你的频道带进来"), message: L10n.text("可保存多个 M3U / TXT 列表或 TVBox 直播订阅，再分别选择。添加直播源不会覆盖点播配置。"), action: L10n.text("添加直播源")) { store.showImport(.live) }
                    }
                } else {
                    HStack {
                        Picker(L10n.text("频道分类方式"), selection: $browser.grouping) {
                            ForEach(ChannelGrouping.allCases) { Text(L10n.string($0.title)).tag($0) }
                        }.pickerStyle(.segmented).labelsHidden().frame(width: 180)
                        Picker(L10n.text("频道分组"), selection: $browser.group) {
                            ForEach(groups, id: \.self) { name in Text("\(L10n.channelGroup(name, automatic: browser.grouping == .automatic)) (\(store.channelIndex.count(group: name, grouping: browser.grouping)))").tag(name) }
                        }.labelsHidden().frame(width: 180)
                        Spacer()
                        TextField(L10n.text("搜索频道"), text: $browser.query).textFieldStyle(.roundedBorder).frame(maxWidth: 210)
                    }
                    if browser.layout == .list {
                        LazyVStack(spacing: 6) {
                            ForEach(visibleSections) { section in
                                SwiftUI.Section {
                                    ForEach(section.channels) { channel in ChannelRow(channel: channel) { store.playChannel(channel) }.equatable().id(channel.id) }
                                } header: { channelSectionTitle(section) }
                            }
                        }
                    } else {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 210), spacing: 14)], spacing: 14) {
                            ForEach(visibleSections) { section in
                                SwiftUI.Section {
                                    ForEach(section.channels) { channel in ChannelTile(channel: channel) { store.playChannel(channel) }.equatable().id(channel.id) }
                                } header: { channelSectionTitle(section) }
                            }
                        }
                    }
                    if visibleSections.isEmpty && !store.liveLoading { Text(L10n.text("没有匹配的频道。")).foregroundStyle(Theme.muted).padding() }
                }
            }.padding(32)
        }
        .task(id: filterKey) {
            let index = store.channelIndex, group = browser.group, query = browser.query, grouping = browser.grouping
            let result = await Task.detached(priority: .userInitiated) { index.sections(group: group, query: query, grouping: grouping) }.value
            guard !Task.isCancelled else { return }
            visibleSections = result; let channels = result.flatMap(\.channels); store.setLiveNavigation(channels)
            if restorePending && !store.liveLoading {
                restorePending = false
                if let id = browser.lastChannelID, channels.contains(where: { $0.id == id }) {
                    await Task.yield()
                    guard !Task.isCancelled else { return }
                    proxy.scrollTo(id, anchor: .center)
                }
            }
        }
        .onChange(of: store.channelRevision) { _ in if !store.liveLoading && !groups.contains(browser.group) { browser.group = "全部" } }
        }
    }
    private func channelSectionTitle(_ section: ChannelSection) -> some View {
        HStack(spacing: 9) {
            Text(L10n.channelGroup(section.name, automatic: browser.grouping == .automatic)).font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.accent)
            Text(L10n.text("\(section.channels.count) 个频道")).font(.system(size: 10)).foregroundStyle(Theme.muted)
            Rectangle().fill(Theme.muted.opacity(0.15)).frame(height: 1)
        }.padding(.top, 12).padding(.bottom, 8)
    }
    private func sourceName(_ source: SavedLiveSource) -> String {
        guard let result = probe.liveResult(source), result.outcome == .success else { return source.name }
        return source.name + "【\(result.milliseconds)ms】"
    }
}

private struct LiveFilterKey: Hashable { var revision: Int; var group: String; var query: String; var grouping: ChannelGrouping }

private struct ChannelTile: View, Equatable {
    let channel: Channel
    let play: () -> Void
    static func == (lhs: Self, rhs: Self) -> Bool { lhs.channel == rhs.channel }
    var body: some View {
        Button(action: play) {
            HStack(spacing: 13) {
                ChannelLogo(url: channel.logo, symbolSize: 23).frame(width: 45, height: 42)
                VStack(alignment: .leading, spacing: 6) {
                    Text(channel.name).font(.system(size: 13, weight: .medium)).foregroundStyle(.white).lineLimit(1)
                    HStack(spacing: 7) {
                        Text(channel.group).lineLimit(1)
                        if channel.urls.count > 1 { Text(L10n.text("\(channel.urls.count) 条线路")).foregroundStyle(Theme.accent.opacity(0.8)).lineLimit(1) }
                    }.font(.system(size: 10)).foregroundStyle(Theme.muted)
                }
                Spacer(minLength: 0)
                Image(systemName: "play.fill").font(.system(size: 10)).foregroundStyle(Theme.muted)
            }.frame(height: 42).padding(17).background(Theme.panel, in: RoundedRectangle(cornerRadius: 10))
        }.buttonStyle(.plain)
    }
}

private struct ChannelRow: View, Equatable {
    let channel: Channel
    let play: () -> Void
    static func == (lhs: Self, rhs: Self) -> Bool { lhs.channel == rhs.channel }
    var body: some View {
        Button(action: play) {
            HStack(spacing: 14) {
                ChannelLogo(url: channel.logo, symbolSize: 21).frame(width: 34, height: 32)
                Text(channel.name).font(.system(size: 13, weight: .medium)).foregroundStyle(.white).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
                Text(channel.group).font(.system(size: 11)).foregroundStyle(Theme.muted).lineLimit(1).frame(width: 110, alignment: .leading)
                Text(L10n.text("\(channel.urls.count) 条线路")).font(.system(size: 10)).monospacedDigit().foregroundStyle(Theme.accent.opacity(0.8)).frame(width: 70, alignment: .trailing)
                Image(systemName: "play.fill").font(.system(size: 10)).foregroundStyle(Theme.muted).frame(width: 20)
            }.frame(height: 38).padding(.horizontal, 16).padding(.vertical, 9)
                .background(Theme.panel, in: RoundedRectangle(cornerRadius: 8)).contentShape(Rectangle())
        }.buttonStyle(.plain)
    }
}

private struct ChannelLogo: View {
    let url: String
    let symbolSize: CGFloat
    var body: some View {
        Group {
            if let url = logoURL {
                AsyncImage(url: url) { image in image.resizable().scaledToFit() } placeholder: { placeholder }
            } else { placeholder }
        }
    }
    private var placeholder: some View { Image(systemName: "tv").font(.system(size: symbolSize)).foregroundStyle(Theme.accent.opacity(0.8)) }
    private var logoURL: URL? {
        guard let url = URL(string: url), ["http", "https"].contains(url.scheme ?? ""), url.host != nil else { return nil }; return url
    }
}
