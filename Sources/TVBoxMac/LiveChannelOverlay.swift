import SwiftUI
import TVBoxCore

@MainActor final class LiveOverlayState: ObservableObject {
    @Published private(set) var expanded = false
    private var inside = false
    private var hideTask: Task<Void, Never>?
    private let delay: UInt64
    init(delay: UInt64 = 3_000_000_000) { self.delay = delay }
    func hover(_ value: Bool) {
        inside = value
        if value { open() } else { schedule() }
    }
    func open() { hideTask?.cancel(); expanded = true; if !inside { schedule() } }
    func activity() { if expanded { hideTask?.cancel(); if !inside { schedule() } } }
    func close() { hideTask?.cancel(); hideTask = nil; expanded = false }
    private func schedule() {
        hideTask?.cancel()
        guard expanded else { return }
        hideTask = Task { [weak self, delay] in
            do { try await Task.sleep(nanoseconds: delay) } catch { return }
            guard let self, !Task.isCancelled, !self.inside else { return }
            self.expanded = false; self.hideTask = nil
        }
    }
    deinit { hideTask?.cancel() }
}

@MainActor final class LiveProgrammeModel: ObservableObject {
    @Published private(set) var programmes: [Programme] = []
    @Published private(set) var loading = false
    @Published private(set) var error: String?
    private let service = ProgrammeGuideService()
    private var generation = UUID()
    func load(channel: Channel, day: Date) async {
        let token = UUID(); generation = token; programmes = []; error = nil; loading = true
        do {
            let items = try await service.programmes(channel: channel, day: day)
            guard generation == token, !Task.isCancelled else { return }
            programmes = items; loading = false
        } catch {
            guard generation == token, !Task.isCancelled else { return }
            self.error = error.localizedDescription; loading = false
        }
    }
}

/// Only the narrow left pane accepts pointer events. The remaining video stays
/// clear and continues to receive the native player's controls.
struct LiveChannelOverlay: View {
    @EnvironmentObject var store: AppStore
    @ObservedObject var browser: LiveBrowserState
    @StateObject var visibility: LiveOverlayState
    @StateObject private var guide = LiveProgrammeModel()
    @State private var query = ""
    @State private var sections: [ChannelSection] = []
    @State private var showGroups = false
    @State private var guideChannel: Channel?
    @State private var day = Calendar.current.startOfDay(for: Date())
    @State private var refresh = 0
    @MainActor init(browser: LiveBrowserState, visibility: LiveOverlayState? = nil, initialGuide: Channel? = nil, groupsExpanded: Bool = false) {
        self.browser = browser
        _showGroups = State(initialValue: groupsExpanded)
        _visibility = StateObject(wrappedValue: visibility ?? LiveOverlayState()); _guideChannel = State(initialValue: initialGuide)
    }
    private var filterKey: String { "\(store.channelRevision)|\(browser.grouping)|\(browser.group)|\(query)" }
    private var groups: [String] { store.channelIndex.groups(for: browser.grouping) }
    private var guideKey: String { "\(guideChannel?.id ?? "")|\(day)|\(refresh)" }
    private var displayDay: String { day.formatted(.dateTime.month().day().weekday().locale(Locale(identifier: "zh_CN"))) }
    var body: some View {
        GeometryReader { geometry in
            HStack(spacing: 0) {
                if visibility.expanded {
                    pane.frame(width: min(220, max(190, geometry.size.width * 0.22)))
                        .background(LinearGradient(colors: [.black.opacity(0.68), .black.opacity(0.42), .clear], startPoint: .leading, endPoint: .trailing))
                        .transition(.move(edge: .leading).combined(with: .opacity))
                } else {
                    Button { visibility.open() } label: {
                        VStack(spacing: 9) { Image(systemName: "list.bullet"); Text("选\n台").lineSpacing(3); Image(systemName: "chevron.right").font(.system(size: 9)) }
                            .font(.system(size: 12, weight: .medium)).foregroundStyle(.white.opacity(0.85))
                            .frame(width: 26, height: 116).background(.black.opacity(0.22), in: RoundedRectangle(cornerRadius: 7))
                    }.buttonStyle(.plain).accessibilityLabel("展开直播频道列表").help("鼠标移入选台，离开 3 秒后收起")
                }
            }
            .frame(height: max(0, geometry.size.height - 84))
            .contentShape(Rectangle())
            .onHover { visibility.hover($0) }
            .animation(.easeInOut(duration: 0.18), value: visibility.expanded)
        }
        .task(id: filterKey) {
            let index = store.channelIndex, query = query, group = browser.group, grouping = browser.grouping
            let result = await Task.detached(priority: .userInitiated) { index.sections(group: group, query: query, grouping: grouping) }.value
            guard !Task.isCancelled else { return }; sections = result; store.setLiveNavigation(result.flatMap(\.channels))
        }
        .task(id: guideKey) {
            guard let channel = guideChannel else { return }
            await guide.load(channel: channel, day: day)
        }
        .onChange(of: query) { _ in visibility.activity() }
        .onChange(of: browser.group) { _ in visibility.activity() }
        .onChange(of: browser.grouping) { _ in visibility.activity() }
        .onChange(of: store.channelRevision) { _ in if !store.liveLoading && !groups.contains(browser.group) { browser.group = "全部" } }
        .onChange(of: store.playback?.video.id) { _ in guideChannel = nil }
        .onDisappear { visibility.close() }
        .foregroundStyle(.white).tint(Theme.accent)
    }
    private var pane: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                if guideChannel != nil {
                    Button { guideChannel = nil; visibility.activity() } label: { Image(systemName: "chevron.left") }.help("返回频道列表")
                    Text("节目预告 / 回看").font(.system(size: 13, weight: .semibold)).lineLimit(1)
                } else {
                    Image(systemName: "list.bullet").foregroundStyle(Theme.accent)
                    Text("直播频道").font(.system(size: 14, weight: .semibold))
                    Text("\(store.channels.count)").font(.system(size: 10)).foregroundStyle(.white.opacity(0.55))
                }
                Spacer(minLength: 0)
                Button { visibility.close() } label: { Image(systemName: "chevron.left.2") }.help("收起频道列表")
            }.buttonStyle(.plain)
            if let channel = guideChannel { programmePane(channel) }
            else { channelPane }
        }.padding(.horizontal, 12).padding(.top, 14).padding(.bottom, 10)
    }
    private var channelPane: some View {
        VStack(spacing: 8) {
            groupChooser
            if !showGroups {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.white.opacity(0.55))
                TextField("搜索频道", text: $query).textFieldStyle(.plain).font(.system(size: 12))
                if !query.isEmpty { Button { query = "" } label: { Image(systemName: "xmark.circle.fill") }.buttonStyle(.plain) }
            }.padding(7).background(.white.opacity(0.09), in: RoundedRectangle(cornerRadius: 6))
            ScrollViewReader { proxy in
                ScrollView(showsIndicators: false) {
                    LazyVStack(spacing: 3) {
                        ForEach(sections) { section in
                            SwiftUI.Section {
                            ForEach(section.channels) { channel in
                            HStack(spacing: 4) {
                                Button {
                                    visibility.activity()
                                    if store.playback?.video.id != channel.id || store.playback?.catchupProgramme != nil { store.playChannel(channel) }
                                } label: {
                                    HStack(spacing: 7) {
                                        Image(systemName: store.playback?.video.id == channel.id ? "waveform" : "play.fill")
                                            .font(.system(size: 10)).frame(width: 14).foregroundStyle(store.playback?.video.id == channel.id ? Theme.accent : .white.opacity(0.45))
                                        VStack(alignment: .leading, spacing: 3) {
                                            Text(channel.name).font(.system(size: 12, weight: .medium)).lineLimit(1)
                                            Text(channel.group).font(.system(size: 9)).foregroundStyle(.white.opacity(0.55)).lineLimit(1)
                                        }
                                        Spacer(minLength: 0)
                                    }.frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 8).contentShape(Rectangle())
                                }.buttonStyle(.plain).help("播放 \(channel.name)")
                                if channel.guide?.url.isEmpty == false {
                                    Button { guideChannel = channel; day = Calendar.current.startOfDay(for: Date()); visibility.activity() } label: {
                                        Image(systemName: "calendar.badge.clock").font(.system(size: 13)).frame(width: 24, height: 34).foregroundStyle(.white.opacity(0.8))
                                    }.buttonStyle(.plain).help("查看 \(channel.name) 的节目预告和回看").accessibilityLabel("\(channel.name) 节目预告和回看")
                                }
                            }.padding(.horizontal, 7).background(store.playback?.video.id == channel.id ? Theme.accent.opacity(0.18) : .clear, in: RoundedRectangle(cornerRadius: 6)).id(channel.id)
                            }
                            } header: {
                                HStack {
                                    Text(section.name).font(.system(size: 10, weight: .semibold)).foregroundStyle(Theme.accent)
                                    Spacer(); Text("\(section.channels.count)").font(.system(size: 9)).foregroundStyle(.white.opacity(0.5))
                                }.padding(.horizontal, 7).padding(.top, 9).padding(.bottom, 3)
                            }
                        }
                        if sections.isEmpty { Text("没有匹配的频道").font(.system(size: 11)).foregroundStyle(.white.opacity(0.6)).padding(.vertical, 20) }
                    }
                }
                .task(id: "\(visibility.expanded)|\(filterKey)|\(sections.first?.id ?? "")") {
                    guard visibility.expanded, query.isEmpty, let id = store.playback?.video.id else { return }
                    await Task.yield(); proxy.scrollTo(id, anchor: .center)
                }
            }
            }
            Text("移开鼠标 3 秒后收起").font(.system(size: 9)).foregroundStyle(.white.opacity(0.4)).frame(maxWidth: .infinity, alignment: .leading)
        }
    }
    private var groupChooser: some View {
        VStack(spacing: 7) {
            Button { showGroups.toggle(); visibility.activity() } label: {
                HStack(spacing: 5) {
                    Image(systemName: "square.stack.3d.up").foregroundStyle(Theme.accent)
                    Text(browser.group).lineLimit(1)
                    Spacer(minLength: 0)
                    Text(browser.grouping.title).font(.system(size: 9)).foregroundStyle(.white.opacity(0.5))
                    Image(systemName: showGroups ? "chevron.up" : "chevron.down").font(.system(size: 9))
                }.font(.system(size: 11)).padding(7).background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 6))
            }.buttonStyle(.plain).help("选择频道分组")
            if showGroups {
                Picker("频道分类方式", selection: $browser.grouping) { ForEach(ChannelGrouping.allCases) { Text($0.title).tag($0) } }
                    .pickerStyle(.segmented).labelsHidden().controlSize(.small)
                ScrollView(showsIndicators: true) {
                    LazyVStack(spacing: 2) {
                        ForEach(groups, id: \.self) { name in
                            Button { browser.group = name; showGroups = false; visibility.activity() } label: {
                                HStack {
                                    Text(name).lineLimit(1); Spacer()
                                    Text("\(store.channelIndex.count(group: name, grouping: browser.grouping))").monospacedDigit().fixedSize().foregroundStyle(.white.opacity(0.5))
                                    Image(systemName: "checkmark").foregroundStyle(Theme.accent).frame(width: 12).opacity(browser.group == name ? 1 : 0)
                                }.font(.system(size: 11)).padding(.horizontal, 6).padding(.vertical, 6).frame(maxWidth: .infinity).contentShape(Rectangle())
                            }.buttonStyle(.plain)
                        }
                    }
                }.frame(maxHeight: .infinity)
            }
        }
    }
    private func programmePane(_ channel: Channel) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(channel.name).font(.system(size: 12, weight: .medium)).lineLimit(1)
            HStack(spacing: 4) {
                Button { changeDay(-1) } label: { Image(systemName: "chevron.left").frame(width: 24, height: 22) }.help("前一天")
                Text(displayDay).font(.system(size: 11)).frame(maxWidth: .infinity)
                Button { day = Calendar.current.startOfDay(for: Date()); visibility.activity() } label: { Text("今天").font(.system(size: 10)) }
                Button { changeDay(1) } label: { Image(systemName: "chevron.right").frame(width: 24, height: 22) }.help("后一天")
            }.buttonStyle(.plain)
            if guide.loading { ProgressView("加载节目单…").font(.system(size: 11)).frame(maxWidth: .infinity, maxHeight: .infinity) }
            else if let error = guide.error {
                VStack(spacing: 12) {
                    Text(error).font(.system(size: 11)).foregroundStyle(.white.opacity(0.7))
                    Button("重试") { refresh += 1; visibility.activity() }
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                    ScrollView(showsIndicators: false) {
                        LazyVStack(alignment: .leading, spacing: 6) {
                            ForEach(guide.programmes) { programme in programmeRow(programme, channel: channel).id(programme.id) }
                            if guide.programmes.isEmpty { Text("该日期没有可用节目单").font(.system(size: 11)).foregroundStyle(.white.opacity(0.6)).padding(.vertical, 20) }
                        }
                    }.task(id: guide.programmes.first?.id) {
                        let now = Date()
                        guard Calendar.current.isDateInToday(day), let item = guide.programmes.first(where: { $0.isOnAir(at: now) || $0.start > now }) else { return }
                        await Task.yield(); proxy.scrollTo(item.id, anchor: .top)
                    }
                }
            }
            if store.playback?.catchupProgramme != nil, let playing = store.playingChannel {
                Button { store.playChannel(playing); visibility.activity() } label: { Label("返回直播", systemImage: "dot.radiowaves.left.and.right").font(.system(size: 11)) }.buttonStyle(.plain).foregroundStyle(Theme.accent)
            }
            Text(channel.guide?.catchup == nil ? "此源未提供回看地址" : "可回看节目显示播放按钮").font(.system(size: 9)).foregroundStyle(.white.opacity(0.45))
        }
    }
    private func programmeRow(_ programme: Programme, channel: Channel) -> some View {
        let now = Date(), playable = channel.guide?.catchup?.playbackURL(programme: programme, liveURL: channel.urls.first ?? "", now: now) != nil
        return VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(programme.start.formatted(.dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits).locale(Locale(identifier: "zh_CN")))).monospacedDigit()
                Spacer()
                Text(programme.isOnAir(at: now) ? "正在播出" : programme.start > now ? "预告" : playable ? "可回看" : "已播出")
            }.font(.system(size: 9)).foregroundStyle(programme.isOnAir(at: now) ? Theme.accent : .white.opacity(0.6))
            HStack(alignment: .top) {
                Text(programme.title).font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                if playable {
                    Button { store.playCatchup(programme, channel: channel); visibility.activity() } label: { Image(systemName: "play.circle.fill").font(.system(size: 19)).foregroundStyle(Theme.accent) }
                        .buttonStyle(.plain).help("回看 \(programme.title)")
                }
            }
            if !programme.summary.isEmpty { Text(programme.summary).font(.system(size: 10)).foregroundStyle(.white.opacity(0.55)).lineLimit(3) }
        }.padding(9).background(.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 6))
    }
    private func changeDay(_ offset: Int) {
        if let date = Calendar.current.date(byAdding: .day, value: offset, to: day) { day = date; visibility.activity() }
    }
}
