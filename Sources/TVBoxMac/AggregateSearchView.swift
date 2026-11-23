import SwiftUI
import TVBoxCore

@MainActor final class AggregateSearchModel: ObservableObject {
    @Published var query = ""
    @Published private(set) var submitted = ""
    @Published private(set) var hits: [VODSearchHit] = []
    @Published private(set) var completed = 0
    @Published private(set) var failed = 0
    @Published private(set) var total = 0
    @Published private(set) var searching = false
    private var task: Task<Void, Never>?

    func submit(service: TVService, sources: [VODSearchSource], availability: VODAvailability) {
        task?.cancel()
        let keyword = query.trimmingCharacters(in: .whitespacesAndNewlines)
        submitted = keyword
        hits = []
        completed = 0
        failed = 0
        total = keyword.isEmpty ? 0 : sources.count
        searching = total > 0
        guard searching else { return }
        task = Task { [weak self] in
            var seen = Set<String>()
            await service.searchAcrossSources(sources, query: keyword, availability: availability) { _, results, success in
                guard let self, !Task.isCancelled else { return }
                self.completed += 1
                if !success { self.failed += 1 }
                self.hits += results.filter { seen.insert($0.id).inserted }
            }
            guard !Task.isCancelled else { return }
            self?.searching = false
        }
    }

    deinit { task?.cancel() }
}

struct AggregateSearchView: View {
    @EnvironmentObject var store: AppStore
    @ObservedObject var model: AggregateSearchModel
    @State private var sourceID = ""
    @State private var chosen = [String: String]()
    private let columns = [GridItem(.adaptive(minimum: 165, maximum: 225), spacing: 20)]

    private var visibleHits: [VODSearchHit] {
        model.hits.filter { store.isVisible($0.video, site: $0.source.site) }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                Text(L10n.text("聚合搜索")).font(.system(size: 23, weight: .semibold))
                HStack {
                    TextField(L10n.text("搜索已导入的点播源"), text: $model.query)
                        .textFieldStyle(.roundedBorder).onSubmit(submit)
                    Button(L10n.text("搜索"), action: submit).buttonStyle(.borderedProminent)
                        .keyboardShortcut(.defaultAction)
                    let choices = Array(Set(visibleHits.map(\.source))).sorted { $0.name < $1.name }
                    if !choices.isEmpty {
                        Picker(L10n.text("结果来源"), selection: $sourceID) {
                            Text(L10n.text("全部片源")).tag("")
                            ForEach(choices) { Text($0.name).tag($0.id) }
                        }.labelsHidden().frame(maxWidth: 230)
                    }
                }
                if model.searching {
                    ProgressView(value: Double(model.completed), total: Double(model.total)) {
                        Text(L10n.text("正在搜索片源 · \(model.completed) / \(model.total)"))
                    }
                }
                if model.failed > 0 {
                    Text(L10n.text("\(model.failed) 个接口未能返回结果，可重试搜索。")).font(.caption).foregroundStyle(Theme.muted)
                }
                if model.submitted.isEmpty {
                    Text(L10n.text("输入片名，可同时搜索已导入的点播源。")).foregroundStyle(Theme.muted)
                } else if model.total == 0 {
                    EmptyViewCard(icon: "externaldrive", title: L10n.text("没有可搜索的点播源"),
                                  message: L10n.text("请先导入包含可搜索接口的点播配置。"),
                                  action: L10n.text("添加点播源")) { store.showImport(.vod) }
                } else if !model.searching && visibleHits.isEmpty {
                    EmptyViewCard(icon: "magnifyingglass", title: L10n.text("没有找到影片"),
                                  message: L10n.text("试试其他关键词、分类或影视源。"))
                } else {
                    results
                }
            }.padding(32)
        }
        .onChange(of: model.submitted) { _ in sourceID = ""; chosen = [:] }
        .onChange(of: model.hits.count) { _ in
            if !sourceID.isEmpty && !model.hits.contains(where: { $0.source.id == sourceID }) { sourceID = "" }
        }
    }

    private var results: some View {
        let grouped = Dictionary(grouping: visibleHits) { VODMatch.titleKey($0.video) }
        let keys = grouped.keys.sorted()
        return LazyVGrid(columns: columns, alignment: .leading, spacing: 25) {
            ForEach(keys, id: \.self) { key in
                let alternatives = (grouped[key] ?? []).sorted { ($0.source.name, $0.id) < ($1.source.name, $1.id) }
                let visible = alternatives.filter { sourceID.isEmpty || $0.source.id == sourceID }
                if let hit = visible.first(where: { $0.id == chosen[key] }) ?? visible.first {
                    VStack(alignment: .leading, spacing: 7) {
                        VideoCard(video: hit.video, index: 0) { open(hit) }
                        HStack(spacing: 5) {
                            Text(hit.source.name).lineLimit(1).help(hit.source.name)
                            Spacer(minLength: 0)
                            if alternatives.count > 1 {
                                Menu(L10n.text("换源")) {
                                    ForEach(alternatives) { option in
                                        Button(option.source.name) {
                                            if !sourceID.isEmpty && sourceID != option.source.id { sourceID = option.source.id }
                                            chosen[key] = option.id
                                        }
                                    }
                                }.fixedSize()
                            }
                        }.font(.caption).foregroundStyle(Theme.muted)
                    }
                }
            }
        }
    }

    private func submit() {
        sourceID = ""; chosen = [:]
        store.searchAll(model.query)
    }

    private func open(_ hit: VODSearchHit) {
        guard let source = store.searchSources.first(where: { $0.id == hit.source.id }) else {
            store.alert = L10n.text("片源已更改，请重新搜索。")
            return
        }
        store.show(hit.video, site: source.site)
    }
}

struct PlaybackSourceSwitchButton: View {
    @EnvironmentObject var store: AppStore
    let current: Playback
    @State private var presented = false
    var body: some View {
        if current.site != nil && !current.isLive {
            Button { presented.toggle() } label: {
                Label(L10n.text("播放页换源"), systemImage: "arrow.left.arrow.right").playbackActionLabel()
            }
            .popover(isPresented: $presented) {
                PlaybackSourcePicker(current: current, presented: $presented)
                    .environmentObject(store)
            }
            .onChange(of: current.sessionID) { _ in presented = false }
        }
    }
}

private struct PlaybackSourcePicker: View {
    @EnvironmentObject var store: AppStore
    let current: Playback
    @Binding var presented: Bool
    @State private var loading = true
    @State private var results = VODPlaybackSearchCache.Results()
    @State private var sources: [VODSearchSource] = []
    @State private var initialized = false
    @State private var lastListFrame: CGRect?
    @State private var selected: VODSearchHit?
    @State private var error: String?

    private var target: VODPlaybackSearch {
        VODPlaybackSearch(video: current.video, episode: current.episode, singleEpisode: current.line.episodes.count == 1)
    }

    private var cacheKey: VODPlaybackSearchCache.Key {
        VODPlaybackSearchCache.Key(siteID: current.site?.id ?? "", search: target)
    }

    private var canLoadMore: Bool { results.checked.count < sources.count && selected == nil }

    private func options(startingAt pageIndex: Int = 0) -> [VODSearchHit] {
        results.pages.dropFirst(pageIndex).flatMap { page in
            let visible = page.filter { !results.rejected.contains($0.id) && store.isVisible($0.video, site: $0.source.site) }
            return VODMatch.topPlaybackSources(for: current.video, episode: current.episode,
                                               singleEpisode: target.singleEpisode, from: visible)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            VStack(alignment: .leading, spacing: 4) {
                Text(L10n.text("切换播放片源")).font(.headline)
                Text("\(current.video.title) · \(current.episode.name)")
                    .lineLimit(2).foregroundStyle(Theme.muted)
            }
            if loading {
                ProgressView(value: Double(results.checked.count), total: Double(max(1, sources.count))) {
                    Text(L10n.text("正在搜索片源 · \(results.checked.count) / \(sources.count)"))
                }
            }
            if let selected { ProgressView(L10n.text("正在检查同一集…")).help(selected.source.site.name) }
            if let error { Text(error).foregroundStyle(Theme.accent) }
            let options = self.options()
            if options.isEmpty && !loading {
                Text(L10n.text("没有找到其他可用片源。")).foregroundStyle(Theme.muted)
            } else if !options.isEmpty {
                let showMore = results.checked.count < sources.count
                let listHeight = min(356, CGFloat((options.count + (showMore ? 1 : 0)) * 36 - 4))
                ScrollView {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(options) { hit in
                            Button {
                                error = nil; selected = hit
                            } label: {
                                HStack {
                                    Text(hit.source.site.name).lineLimit(1).help(hit.source.site.name)
                                    Spacer()
                                    if !hit.video.year.isEmpty { Text(hit.video.year).foregroundStyle(Theme.muted) }
                                    Image(systemName: "chevron.right").foregroundStyle(Theme.accent)
                                }
                                .padding(.horizontal, 10).frame(minHeight: 32)
                                .background(Theme.panel, in: RoundedRectangle(cornerRadius: 7))
                                .contentShape(Rectangle())
                            }.buttonStyle(.plain).disabled(selected != nil)
                        }
                        if showMore {
                            Button(L10n.text("查看更多片源"), action: loadMore)
                                .frame(maxWidth: .infinity, minHeight: 32)
                                .disabled(loading || !canLoadMore)
                        }
                    }
                    // Keep a short list scrollable so it also supports pulling for more.
                    .padding(.bottom, showMore ? 12 : 0)
                    .background {
                        GeometryReader { geometry in
                            Color.clear.preference(key: PlaybackSourceListFrame.self,
                                                   value: geometry.frame(in: .named("playbackSourceList")))
                        }
                    }
                }
                .coordinateSpace(name: "playbackSourceList")
                .frame(height: listHeight)
                .onPreferenceChange(PlaybackSourceListFrame.self) { frame in
                    let previous = lastListFrame
                    lastListFrame = frame
                    guard let frame, let previous, abs(previous.height - frame.height) < 1,
                          frame.minY < previous.minY - 0.5, frame.maxY <= listHeight + 4 else { return }
                    loadMore()
                }
            }
        }
        .padding(18).frame(width: 380).background(Theme.background)
        .task(id: loading) {
            guard loading else { return }
            if !initialized {
                let candidates = VODSearchSource.playbackAlternatives(in: store.searchSources, excluding: current.site)
                let direct = candidates.filter { $0.site.supported }
                let crawlers = candidates.filter { !$0.site.supported }
                sources = Array(direct.prefix(6)) + Array(crawlers.prefix(2)) + direct.dropFirst(6) + crawlers.dropFirst(2)
                if let cached = store.playbackSearchCache.results(for: cacheKey) { results = cached.retaining(sources) }
                initialized = true
                if !options().isEmpty {
                    loading = false
                    return
                }
            }
            let remaining = sources.filter { results.checked[$0.id] == nil }
            let pageIndex = results.pages.count
            await store.service.searchPlaybackSources(remaining, for: target, availability: store.availability,
                                                       hasResults: { !options(startingAt: pageIndex).isEmpty }) { source, hits in
                results.checked[source.id] = source.site
                if !hits.isEmpty {
                    if results.pages.count == pageIndex { results.pages.append(hits) }
                    else { results.pages[pageIndex] += hits }
                }
                store.playbackSearchCache.save(results, for: cacheKey)
            }
            if !Task.isCancelled { loading = false }
        }
        .task(id: selected?.id) {
            guard let selected else { return }
            do {
                try await store.switchPlaybackSource(to: selected, current: current)
                if !Task.isCancelled { presented = false }
            } catch {
                guard !Task.isCancelled else { return }
                if error is VODSwitchFailure {
                    results.rejected.insert(selected.id)
                    store.playbackSearchCache.save(results, for: cacheKey)
                }
                self.error = L10n.string(error.localizedDescription)
                self.selected = nil
                if options().isEmpty && canLoadMore { loading = true }
            }
        }
    }

    private func loadMore() {
        guard !loading, canLoadMore else { return }
        error = nil
        loading = true
    }
}

private struct PlaybackSourceListFrame: PreferenceKey {
    static let defaultValue: CGRect? = nil
    static func reduce(value: inout CGRect?, nextValue: () -> CGRect?) { value = nextValue() ?? value }
}

enum VODSwitchFailure: LocalizedError {
    case noEpisode
    var errorDescription: String? { "这个片源没有找到同一集的可播放线路。" }
}
