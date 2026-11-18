import SwiftUI
import AppKit
import TVBoxCore

private struct SourceAction: Identifiable {
    var id: String
    var name: String
    var live: Bool
    var address: String = ""
}

struct SourcesView: View {
    @EnvironmentObject var store: AppStore
    @ObservedObject var probe: NetworkProbeModel
    @ObservedObject var browser: LiveBrowserState
    @State private var removal: SourceAction?
    @State private var editing: SourceAction?
    @State private var rename: SourceAction?
    @State private var editedName = ""
    @State private var loadingSubscription: String?

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 28) {
                HStack {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(L10n.text("管理你的内容来源")).font(.system(size: 27, weight: .semibold))
                        Text(L10n.text("点播与直播分别保存、分别选择。切换时互不影响。")).font(.system(size: 12)).foregroundStyle(Theme.muted)
                    }
                    Spacer()
                    Button(L10n.text("批量网络探测")) { store.section = .network }
                    Button(L10n.text("导入文件")) { store.importFile() }
                    Button(L10n.text("添加内容源")) { store.showImport() }.buttonStyle(.borderedProminent)
                }
                if let notice = store.importNotice {
                    VStack(alignment: .trailing, spacing: 6) {
                        ErrorBanner(message: notice)
                        Button(L10n.text("关闭提示")) { store.importNotice = nil }.font(.system(size: 10)).buttonStyle(.plain).foregroundStyle(Theme.muted)
                    }
                }
                PlayerPreferenceView()
                AppUpdateView(updates: store.updates)
                vodSection
                liveSection
                activeVODDetails
                activeLiveDetails
                compatibility
                Text(L10n.text("TVBox for macOS · \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? L10n.string("开发版")) · 内置 VLC · Intel / Apple Silicon")).font(.system(size: 10)).foregroundStyle(Theme.muted)
            }.padding(32)
        }
        .confirmationDialog(L10n.text("移除这个源？收藏和播放记录会保留。"), isPresented: Binding(get: { removal != nil }, set: { if !$0 { removal = nil } }), titleVisibility: .visible) {
            if let item = removal {
                Button(L10n.text("移除“\(item.name)”"), role: .destructive) { store.removeSource(item.id, live: item.live); removal = nil }
            }
            Button(L10n.text("取消"), role: .cancel) { removal = nil }
        }
        .sheet(item: $editing) { SourceEditorView(source: $0).environmentObject(store) }
        .alert(L10n.text("重命名来源"), isPresented: Binding(get: { rename != nil }, set: { if !$0 { rename = nil } })) {
            TextField(L10n.text("源名称"), text: $editedName)
            Button(L10n.text("保存")) { if let item = rename { store.renameSource(item.id, name: editedName, live: item.live) }; rename = nil }
            Button(L10n.text("取消"), role: .cancel) { rename = nil }
        }
    }

    private var vodSection: some View {
        VStack(alignment: .leading, spacing: 15) {
            sectionHeader(L10n.text("点播源"), icon: "film", count: store.vodSources.count) { store.showImport(.vod) }
            if store.vodSources.isEmpty {
                Text(L10n.text("还没有点播源。添加 TVBox JSON 配置后，可在“发现”页切换。")).font(.system(size: 12)).foregroundStyle(Theme.muted).padding(22).frame(maxWidth: .infinity, alignment: .leading).background(Theme.panel, in: RoundedRectangle(cornerRadius: 10))
            } else {
                LazyVStack(spacing: 0) {
                    ForEach(store.vodSources) { source in
                        SourceRow(name: source.name, location: source.configuration.location, detail: vodDetail(source), active: source.id == store.sourceLibrary.selectedVODID, loading: store.refreshingSources.contains(source.id), select: { store.selectVODSource(source.id) }, refresh: { Task { await store.refreshSource(source.id, live: false) } }, rename: { beginRename(source.id, name: source.name, live: false) }, copy: { store.copySourceAddress(source.id, live: false) }, edit: { beginEditing(source.id, name: source.name, live: false) }, remove: { removal = SourceAction(id: source.id, name: source.name, live: false) })
                        if source.id != store.vodSources.last?.id { rowDivider }
                    }
                }.background(Theme.panel, in: RoundedRectangle(cornerRadius: 11))
            }
        }
    }

    private func vodDetail(_ source: SavedVODSource) -> String {
        let config = source.configuration
        if config.sites.isEmpty, !config.subscriptions.isEmpty { return L10n.text("\(config.subscriptions.count) 个原始仓库") }
        return L10n.text("\(config.sites.count) 个接口 · \(config.sites.filter(\.supported).count) 个采集 · \(config.sites.filter(\.requiresCSP).count) 个 CSP")
    }

    private var liveSection: some View {
        let sources = probe.orderedLiveSources(store.liveSources, byLatency: browser.sourceSort == .latency)
        return VStack(alignment: .leading, spacing: 15) {
            HStack {
                Label(L10n.text("直播源"), systemImage: "antenna.radiowaves.left.and.right").font(.system(size: 17, weight: .semibold))
                Text("\(sources.count)").font(.system(size: 11)).foregroundStyle(Theme.muted)
                Spacer()
                Picker(L10n.text("直播源排序"), selection: $browser.sourceSort) {
                    ForEach(LiveSourceSort.allCases) { Text($0.title).tag($0) }
                }.labelsHidden().frame(width: 170).help(L10n.text("正常响应优先，按探测时延升序；失败和未探测项排后"))
                Button { store.showImport(.live) } label: { Label(L10n.text("添加直播源"), systemImage: "plus") }.font(.system(size: 12)).buttonStyle(.borderless)
            }
            if store.liveSources.isEmpty {
                Text(L10n.text("还没有直播源。可添加多个 M3U / TXT 列表或 TVBox 直播订阅。")).font(.system(size: 12)).foregroundStyle(Theme.muted).padding(22).frame(maxWidth: .infinity, alignment: .leading).background(Theme.panel, in: RoundedRectangle(cornerRadius: 10))
            } else {
                LazyVStack(spacing: 0) {
                    ForEach(sources) { source in
                        SourceRow(name: source.name, location: source.feedURL ?? source.configuration.location, detail: liveDetail(source), active: source.id == store.sourceLibrary.selectedLiveID, loading: store.refreshingSources.contains(source.id), select: { store.selectLiveSource(source.id) }, refresh: { Task { await store.refreshSource(source.id, live: true) } }, rename: { beginRename(source.id, name: source.name, live: true) }, copy: { store.copySourceAddress(source.id, live: true) }, edit: { beginEditing(source.id, name: source.name, live: true) }, remove: { removal = SourceAction(id: source.id, name: source.name, live: true) }, probeResult: probe.liveResult(source))
                        if source.id != sources.last?.id { rowDivider }
                    }
                }.background(Theme.panel, in: RoundedRectangle(cornerRadius: 11))
            }
        }
    }

    @ViewBuilder private var activeVODDetails: some View {
        if let source = store.selectedVODSource {
            if !source.configuration.subscriptions.isEmpty {
                subscriptionList(source.configuration.subscriptions, title: L10n.text("\(source.name) · 原始仓库 / 子配置"), target: source.configuration.sites.isEmpty ? .automatic : .vod)
            }
            if !source.configuration.sites.isEmpty {
                VStack(alignment: .leading, spacing: 14) {
                    HStack {
                        Text(L10n.text("当前点播接口 · \(source.name)")).font(.system(size: 15, weight: .semibold))
                        Spacer()
                        Button(L10n.text("进入片库")) { store.section = .discover }.font(.system(size: 12))
                    }
                    LazyVStack(spacing: 0) {
                        ForEach(source.configuration.sites) { site in
                            HStack(spacing: 12) {
                                Image(systemName: site.requiresCSP ? "puzzlepiece.extension.fill" : site.supported ? "checkmark.circle.fill" : "puzzlepiece.extension").foregroundStyle(site.requiresCSP ? Theme.accent : site.supported ? Color.green.opacity(0.8) : Theme.muted)
                                Text(site.name).font(.system(size: 12)).lineLimit(1)
                                if source.componentOverrides?[site.id]?.api == site.api {
                                    Text(L10n.text("本机修正组件")).font(.system(size: 10)).foregroundStyle(Theme.accent)
                                }
                                ProbeLatencyTag(result: probe.result(url: site.api, kind: .vod, headers: site.headers))
                                Spacer()
                                Text(site.format).font(.system(size: 10)).foregroundStyle(Theme.muted)
                                if store.service.supports(site) {
                                    if store.siteID == site.id { Text(L10n.text("使用中")).font(.system(size: 10)).foregroundStyle(Theme.accent) }
                                    else { Button(L10n.text("选择")) { store.selectSite(site.id) }.font(.system(size: 11)) }
                                } else { Text(site.type == 3 && site.api.hasPrefix("csp_") ? L10n.text("请刷新配置 / 检查运行时") : L10n.text("待适配")).font(.system(size: 10)).foregroundStyle(Theme.muted) }
                            }.padding(15).contextMenu {
                                if source.componentOverrides?[site.id]?.api == site.api {
                                    Button(L10n.text("恢复源配置中的组件")) { store.resetCSPComponent(sourceID: source.id, siteID: site.id) }
                                }
                            }
                            if site.id != source.configuration.sites.last?.id { rowDivider }
                        }
                    }.background(Theme.panel, in: RoundedRectangle(cornerRadius: 10))
                }
            }
        }
    }

    @ViewBuilder private var activeLiveDetails: some View {
        if let source = store.selectedLiveSource {
            if !source.subscriptions.isEmpty { subscriptionList(source.subscriptions, title: L10n.text("\(source.name) · 直播子配置"), target: .live) }
            HStack {
                VStack(alignment: .leading, spacing: 8) {
                    Text(L10n.text("当前直播 · \(source.name)")).font(.system(size: 14, weight: .semibold))
                    Text(L10n.text("\(store.channels.count) 个频道\(store.liveLoading ? L10n.string(" · 正在加载") : "")")).font(.system(size: 11)).foregroundStyle(Theme.muted)
                }
                Spacer()
                Button(L10n.text("进入直播")) { store.section = .live }
            }.padding(20).overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.line))
        }
    }

    private var compatibility: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L10n.text("兼容说明")).font(.system(size: 14, weight: .semibold))
            Text(L10n.text("点播支持 type 0 XML / type 1 JSON，以及配置含 spider 或 jar 的 type 3 Java / CSP 接口。CSP 在 Mac 内的独立运行时调用，视频仍在软件内播放；旧版保存的配置请先刷新一次。首次启动及 Intel 机型可能需要更长时间。具体分类、搜索和播放能力以接口返回为准。\n\n直播支持 M3U / TXT 与 TVBox lives。暂未支持 JS / Python 爬虫、type 4 远程爬虫、网页嗅探和 parses 解析服务；需要登录或专有运行库的接口可能无法使用。\n\n同一地址再次导入会更新已保存的源，收藏和播放记录保留。"))
                .font(.system(size: 12)).foregroundStyle(Theme.muted).lineSpacing(5)
        }.padding(22).frame(maxWidth: .infinity, alignment: .leading).overlay(RoundedRectangle(cornerRadius: 11).stroke(Theme.line))
    }

    private var rowDivider: some View { Rectangle().fill(Theme.line).frame(height: 1).padding(.horizontal, 17) }
    private func sectionHeader(_ name: String, icon: String, count: Int, add: @escaping () -> Void) -> some View {
        HStack {
            Label(name, systemImage: icon).font(.system(size: 17, weight: .semibold))
            Text("\(count)").font(.system(size: 11)).foregroundStyle(Theme.muted)
            Spacer()
            Button(action: add) { Label(L10n.text("添加\(name)"), systemImage: "plus") }.font(.system(size: 12)).buttonStyle(.borderless)
        }
    }
    private func liveDetail(_ source: SavedLiveSource) -> String {
        if !source.subscriptions.isEmpty { return L10n.text("\(source.subscriptions.count) 个子配置") }
        return source.feedURL == nil ? L10n.text("\(source.channels.count) 个频道") : L10n.text("直播订阅列表")
    }
    private func beginEditing(_ id: String, name: String, live: Bool) {
        editing = SourceAction(id: id, name: name, live: live, address: store.sourceAddress(id, live: live) ?? "")
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
                        else { Label(L10n.text("添加并使用"), systemImage: "plus").font(.system(size: 10)).foregroundStyle(Theme.muted) }
                    }.padding(16).background(Theme.panel, in: RoundedRectangle(cornerRadius: 8))
                }.buttonStyle(.plain).disabled(loadingSubscription != nil || store.importing)
            }
        }
    }
}

private struct SourceEditorView: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.dismiss) var dismiss
    let source: SourceAction
    @State private var name: String
    @State private var address: String
    @State private var saving = false
    @State private var error: String?
    @State private var saveTask: Task<Void, Never>?
    init(source: SourceAction) {
        self.source = source
        _name = State(initialValue: source.name); _address = State(initialValue: source.address)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack {
                Text(source.live ? L10n.text("修改直播源") : L10n.text("修改点播源")).font(.system(size: 24, weight: .semibold))
                Spacer()
                Button(action: cancel) { Image(systemName: "xmark") }.buttonStyle(.plain).help(L10n.text("取消修改"))
            }
            VStack(alignment: .leading, spacing: 8) {
                Text(L10n.text("源名称")).font(.system(size: 12, weight: .medium))
                TextField(L10n.text("源名称"), text: $name).textFieldStyle(.roundedBorder).disabled(saving)
            }
            VStack(alignment: .leading, spacing: 8) {
                Text(source.live ? L10n.text("直播源地址") : L10n.text("配置地址")).font(.system(size: 12, weight: .medium))
                TextField("https://example.com/" + (source.live ? "live.m3u" : "tvbox.json"), text: $address)
                    .textFieldStyle(.plain).font(.system(size: 12, design: .monospaced))
                    .padding(13).background(Theme.panel, in: RoundedRectangle(cornerRadius: 8))
                    .disabled(saving).onSubmit(save)
            }
            Text(L10n.text("只修改名称无需联网。修改地址会先验证内容，成功后替换当前源；其他源和所选源保持不变。"))
                .font(.system(size: 11)).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
            if let error { ErrorBanner(message: error) }
            HStack {
                Button(L10n.text("取消"), action: cancel).keyboardShortcut(.cancelAction)
                Spacer()
                if saving { ProgressView().controlSize(.small) }
                Button(saving ? L10n.text("正在验证…") : L10n.text("保存修改"), action: save)
                    .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                    .disabled(saving || name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }.padding(30).frame(width: 540).background(Theme.background).tint(Theme.accent)
            .interactiveDismissDisabled(saving).onDisappear { saveTask?.cancel() }
    }
    private func cancel() { saveTask?.cancel(); dismiss() }
    private func save() {
        guard !saving else { return }; saving = true; error = nil
        saveTask = Task { @MainActor in
            do {
                try await store.updateSource(source.id, live: source.live, name: name, address: address)
                if !Task.isCancelled { dismiss() }
            } catch is CancellationError {}
            catch { if !Task.isCancelled { self.error = error.localizedDescription } }
            saving = false
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
    let copy: () -> Void
    let edit: () -> Void
    let remove: () -> Void
    var probeResult: ProbeResult? = nil
    @State private var copied = false
    @State private var copyReset: Task<Void, Never>?
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
            if active { Text(L10n.text("使用中")).font(.system(size: 11, weight: .medium)).foregroundStyle(Theme.accent).frame(width: 54) }
            else { Button(L10n.text("选择"), action: select).font(.system(size: 11)).frame(width: 54) }
            Button(action: copyAddress) { Image(systemName: copied ? "checkmark" : "doc.on.doc").frame(width: 20, height: 24) }
                .buttonStyle(.plain).foregroundStyle(copied ? Theme.accent : Theme.muted)
                .disabled(location.isEmpty).help(copied ? L10n.text("已复制源地址") : L10n.text("复制源地址")).accessibilityLabel(L10n.text("复制源地址"))
            Button(action: edit) { Image(systemName: "square.and.pencil").frame(width: 20, height: 24) }
                .buttonStyle(.plain).foregroundStyle(Theme.muted).disabled(loading)
                .help(L10n.text("修改源名称 / 地址")).accessibilityLabel(L10n.text("修改源"))
            Menu {
                Button(L10n.text("复制地址"), action: copyAddress).disabled(location.isEmpty)
                Button(L10n.text("修改名称 / 地址"), action: edit).disabled(loading)
                Button(L10n.text("刷新源"), action: refresh).disabled(loading)
                Button(L10n.text("重命名"), action: rename).disabled(loading)
                Divider()
                Button(L10n.text("移除"), role: .destructive, action: remove)
            } label: { Image(systemName: "ellipsis") }.frame(width: 38).accessibilityLabel(L10n.text("管理\(name)"))
        }.padding(18).onDisappear { copyReset?.cancel() }
    }
    private func copyAddress() {
        copy(); copied = true; copyReset?.cancel()
        copyReset = Task { @MainActor in
            do { try await Task.sleep(nanoseconds: 2_000_000_000) } catch { return }
            copied = false
        }
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
        case .httpError, .networkError: return L10n.text("【失败】")
        case .cancelled: return L10n.text("【已取消】")
        }
    }
}
