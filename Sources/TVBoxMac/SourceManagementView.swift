import SwiftUI
import TVBoxCore

private struct SourceAction: Identifiable {
    var id: String
    var name: String
    var live: Bool
}

struct SourcesView: View {
    @EnvironmentObject var store: AppStore
    @ObservedObject var probe: NetworkProbeModel
    @ObservedObject var browser: LiveBrowserState
    @State private var removal: SourceAction?
    @State private var rename: SourceAction?
    @State private var editedName = ""
    @State private var loadingSubscription: String?

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 28) {
                HStack {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("管理你的内容来源").font(.system(size: 27, weight: .semibold))
                        Text("点播与直播分别保存、分别选择。切换时互不影响。").font(.system(size: 12)).foregroundStyle(Theme.muted)
                    }
                    Spacer()
                    Button("批量网络探测") { store.section = .network }
                    Button("导入文件") { store.importFile() }
                    Button("添加内容源") { store.showImport() }.buttonStyle(.borderedProminent)
                }
                if let notice = store.importNotice {
                    VStack(alignment: .trailing, spacing: 6) {
                        ErrorBanner(message: notice)
                        Button("关闭提示") { store.importNotice = nil }.font(.system(size: 10)).buttonStyle(.plain).foregroundStyle(Theme.muted)
                    }
                }
                vodSection
                liveSection
                activeVODDetails
                activeLiveDetails
                compatibility
                Text("TVBox for macOS · 0.6.4 · 原生 SwiftUI / AVPlayer").font(.system(size: 10)).foregroundStyle(Theme.muted)
            }.padding(32)
        }
        .confirmationDialog("移除这个源？收藏和播放记录会保留。", isPresented: Binding(get: { removal != nil }, set: { if !$0 { removal = nil } }), titleVisibility: .visible) {
            if let item = removal {
                Button("移除“\(item.name)”", role: .destructive) { store.removeSource(item.id, live: item.live); removal = nil }
            }
            Button("取消", role: .cancel) { removal = nil }
        }
        .alert("重命名来源", isPresented: Binding(get: { rename != nil }, set: { if !$0 { rename = nil } })) {
            TextField("源名称", text: $editedName)
            Button("保存") { if let item = rename { store.renameSource(item.id, name: editedName, live: item.live) }; rename = nil }
            Button("取消", role: .cancel) { rename = nil }
        }
    }

    private var vodSection: some View {
        VStack(alignment: .leading, spacing: 15) {
            sectionHeader("点播源", icon: "film", count: store.vodSources.count) { store.showImport(.vod) }
            if store.vodSources.isEmpty {
                Text("还没有点播源。添加 TVBox JSON 配置后，可在“发现”页切换。").font(.system(size: 12)).foregroundStyle(Theme.muted).padding(22).frame(maxWidth: .infinity, alignment: .leading).background(Theme.panel, in: RoundedRectangle(cornerRadius: 10))
            } else {
                LazyVStack(spacing: 0) {
                    ForEach(store.vodSources) { source in
                        SourceRow(name: source.name, location: source.configuration.location, detail: "\(source.configuration.sites.count) 个接口 · \(source.configuration.sites.filter(\.supported).count) 个兼容", active: source.id == store.sourceLibrary.selectedVODID, loading: store.refreshingSources.contains(source.id), select: { store.selectVODSource(source.id) }, refresh: { Task { await store.refreshSource(source.id, live: false) } }, rename: { beginRename(source.id, name: source.name, live: false) }, remove: { removal = SourceAction(id: source.id, name: source.name, live: false) })
                        if source.id != store.vodSources.last?.id { rowDivider }
                    }
                }.background(Theme.panel, in: RoundedRectangle(cornerRadius: 11))
            }
        }
    }

    private var liveSection: some View {
        let sources = probe.orderedLiveSources(store.liveSources, byLatency: browser.sourceSort == .latency)
        return VStack(alignment: .leading, spacing: 15) {
            HStack {
                Label("直播源", systemImage: "antenna.radiowaves.left.and.right").font(.system(size: 17, weight: .semibold))
                Text("\(sources.count)").font(.system(size: 11)).foregroundStyle(Theme.muted)
                Spacer()
                Picker("直播源排序", selection: $browser.sourceSort) {
                    ForEach(LiveSourceSort.allCases) { Text($0.title).tag($0) }
                }.labelsHidden().frame(width: 170).help("正常响应优先，按探测时延升序；失败和未探测项排后")
                Button { store.showImport(.live) } label: { Label("添加直播源", systemImage: "plus") }.font(.system(size: 12)).buttonStyle(.borderless)
            }
            if store.liveSources.isEmpty {
                Text("还没有直播源。可添加多个 M3U / TXT 列表或 TVBox 直播订阅。").font(.system(size: 12)).foregroundStyle(Theme.muted).padding(22).frame(maxWidth: .infinity, alignment: .leading).background(Theme.panel, in: RoundedRectangle(cornerRadius: 10))
            } else {
                LazyVStack(spacing: 0) {
                    ForEach(sources) { source in
                        SourceRow(name: source.name, location: source.feedURL ?? source.configuration.location, detail: liveDetail(source), active: source.id == store.sourceLibrary.selectedLiveID, loading: store.refreshingSources.contains(source.id), select: { store.selectLiveSource(source.id) }, refresh: { Task { await store.refreshSource(source.id, live: true) } }, rename: { beginRename(source.id, name: source.name, live: true) }, remove: { removal = SourceAction(id: source.id, name: source.name, live: true) }, probeResult: probe.liveResult(source))
                        if source.id != sources.last?.id { rowDivider }
                    }
                }.background(Theme.panel, in: RoundedRectangle(cornerRadius: 11))
            }
        }
    }

    @ViewBuilder private var activeVODDetails: some View {
        if let source = store.selectedVODSource {
            if !source.configuration.subscriptions.isEmpty {
                subscriptionList(source.configuration.subscriptions, title: "\(source.name) · 点播子配置", target: .vod)
            }
            if !source.configuration.sites.isEmpty {
                VStack(alignment: .leading, spacing: 14) {
                    HStack {
                        Text("当前点播接口 · \(source.name)").font(.system(size: 15, weight: .semibold))
                        Spacer()
                        Button("进入片库") { store.section = .discover }.font(.system(size: 12))
                    }
                    LazyVStack(spacing: 0) {
                        ForEach(source.configuration.sites) { site in
                            HStack(spacing: 12) {
                                Image(systemName: site.supported ? "checkmark.circle.fill" : "puzzlepiece.extension").foregroundStyle(site.supported ? Color.green.opacity(0.8) : Theme.muted)
                                Text(site.name).font(.system(size: 12)).lineLimit(1)
                                ProbeLatencyTag(result: probe.result(url: site.api, kind: .vod, headers: site.headers))
                                Spacer()
                                Text(site.format).font(.system(size: 10)).foregroundStyle(Theme.muted)
                                if site.supported {
                                    if store.siteID == site.id { Text("使用中").font(.system(size: 10)).foregroundStyle(Theme.accent) }
                                    else { Button("选择") { store.selectSite(site.id) }.font(.system(size: 11)) }
                                } else { Text("待适配").font(.system(size: 10)).foregroundStyle(Theme.muted) }
                            }.padding(15)
                            if site.id != source.configuration.sites.last?.id { rowDivider }
                        }
                    }.background(Theme.panel, in: RoundedRectangle(cornerRadius: 10))
                }
            }
        }
    }

    @ViewBuilder private var activeLiveDetails: some View {
        if let source = store.selectedLiveSource {
            if !source.subscriptions.isEmpty { subscriptionList(source.subscriptions, title: "\(source.name) · 直播子配置", target: .live) }
            HStack {
                VStack(alignment: .leading, spacing: 8) {
                    Text("当前直播 · \(source.name)").font(.system(size: 14, weight: .semibold))
                    Text("\(store.channels.count) 个频道\(store.liveLoading ? " · 正在加载" : "")").font(.system(size: 11)).foregroundStyle(Theme.muted)
                }
                Spacer()
                Button("进入直播") { store.section = .live }
            }.padding(20).overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.line))
        }
    }

    private var compatibility: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("兼容说明").font(.system(size: 14, weight: .semibold))
            Text("点播支持 type 0 XML / type 1 JSON 接口；直播支持 M3U / TXT 列表与 TVBox lives。支持图片前缀 + Base64 配置；一个配置内的多个直播订阅会分别保存，可逐个选择。\n\n暂未支持 Android JAR / CSP、JS / Python 爬虫、type 4 远程爬虫、AES / 密码加密配置、网页嗅探、parses 解析服务和 EPG。\n\n同一地址再次导入会更新已保存的源。旧版单份配置会自动迁移，收藏和播放记录保留。")
                .font(.system(size: 12)).foregroundStyle(Theme.muted).lineSpacing(5)
        }.padding(22).frame(maxWidth: .infinity, alignment: .leading).overlay(RoundedRectangle(cornerRadius: 11).stroke(Theme.line))
    }

    private var rowDivider: some View { Rectangle().fill(Theme.line).frame(height: 1).padding(.horizontal, 17) }
    private func sectionHeader(_ name: String, icon: String, count: Int, add: @escaping () -> Void) -> some View {
        HStack {
            Label(name, systemImage: icon).font(.system(size: 17, weight: .semibold))
            Text("\(count)").font(.system(size: 11)).foregroundStyle(Theme.muted)
            Spacer()
            Button(action: add) { Label("添加\(name)", systemImage: "plus") }.font(.system(size: 12)).buttonStyle(.borderless)
        }
    }
    private func liveDetail(_ source: SavedLiveSource) -> String {
        if !source.subscriptions.isEmpty { return "\(source.subscriptions.count) 个子配置" }
        return source.feedURL == nil ? "\(source.channels.count) 个频道" : "直播订阅列表"
    }
    private func beginRename(_ id: String, name: String, live: Bool) { editedName = name; rename = SourceAction(id: id, name: name, live: live) }
    private func subscriptionList(_ subscriptions: [Subscription], title: String, target: SourceImportTarget) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.system(size: 15, weight: .semibold))
            ForEach(subscriptions) { subscription in
                Button {
                    loadingSubscription = subscription.id
                    Task {
                        await store.importURL(subscription.url, target: target, name: subscription.name)
                        loadingSubscription = nil
                        if let error = store.importError { store.alert = error }
                    }
                } label: {
                    HStack {
                        Image(systemName: "folder").foregroundStyle(Theme.accent)
                        HStack(spacing: 0) {
                            Text(subscription.name).font(.system(size: 12)).lineLimit(1)
                            ProbeLatencyTag(result: probe.result(url: subscription.url, kind: .subscription))
                        }
                        Spacer()
                        if loadingSubscription == subscription.id { ProgressView().controlSize(.small) }
                        else { Label("添加并使用", systemImage: "plus").font(.system(size: 10)).foregroundStyle(Theme.muted) }
                    }.padding(16).background(Theme.panel, in: RoundedRectangle(cornerRadius: 8))
                }.buttonStyle(.plain).disabled(loadingSubscription != nil || store.importing)
            }
        }
    }
}

private struct SourceRow: View {
    let name: String
    let location: String
    let detail: String
    let active: Bool
    let loading: Bool
    let select: () -> Void
    let refresh: () -> Void
    let rename: () -> Void
    let remove: () -> Void
    var probeResult: ProbeResult? = nil
    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: active ? "checkmark.circle.fill" : "circle").font(.system(size: 17)).foregroundStyle(active ? Theme.accent : Theme.muted.opacity(0.4))
            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 9) {
                    Text(name).font(.system(size: 13, weight: .medium))
                    HStack(spacing: 0) {
                        Text(detail).font(.system(size: 10)).foregroundStyle(Theme.muted)
                        ProbeLatencyTag(result: probeResult)
                    }
                }
                Text(displayLocation).font(.system(size: 10, design: .monospaced)).foregroundStyle(Theme.muted).lineLimit(1)
            }.frame(maxWidth: .infinity, alignment: .leading)
            if loading { ProgressView().controlSize(.small) }
            if active { Text("使用中").font(.system(size: 11, weight: .medium)).foregroundStyle(Theme.accent).frame(width: 54) }
            else { Button("选择", action: select).font(.system(size: 11)).frame(width: 54) }
            Menu {
                Button("刷新源", action: refresh).disabled(loading)
                Button("重命名", action: rename)
                Divider()
                Button("移除", role: .destructive, action: remove)
            } label: { Image(systemName: "ellipsis") }.frame(width: 38).accessibilityLabel("管理\(name)")
        }.padding(18)
    }
    private var displayLocation: String {
        guard var components = URLComponents(string: location) else { return location }
        components.query = nil; components.fragment = nil; components.user = nil; components.password = nil
        return components.string ?? location
    }
}

private struct ProbeLatencyTag: View {
    let result: ProbeResult?
    var body: some View {
        if let result {
            Text(label(result)).font(.system(size: 10)).monospacedDigit().fixedSize()
                .foregroundStyle(result.outcome == .success ? Color.green.opacity(0.85) : Theme.muted)
                .help([result.statusCode.map { "HTTP \($0)" }, result.outcome == .cancelled ? nil : "\(result.milliseconds)ms", result.message].compactMap { $0 }.joined(separator: " · "))
        }
    }
    private func label(_ result: ProbeResult) -> String {
        switch result.outcome {
        case .success: return "【\(result.milliseconds)ms】"
        case .httpError, .networkError: return "【失败】"
        case .cancelled: return "【已取消】"
        }
    }
}
