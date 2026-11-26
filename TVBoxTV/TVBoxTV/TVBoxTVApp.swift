import SwiftUI
import TVBoxCore

@main struct TVBoxTVApp: App {
    @StateObject private var store = TelevisionStore()

    var body: some Scene {
        WindowGroup {
            TabView {
                NavigationStack { TVBrowse() }.tabItem { Label("Browse", systemImage: "film") }
                NavigationStack { TVLive() }.tabItem { Label("Live TV", systemImage: "tv") }
                NavigationStack { TVSearch() }.tabItem { Label("Search", systemImage: "magnifyingglass") }
                NavigationStack { TVHistory() }.tabItem { Label("History", systemImage: "clock.arrow.circlepath") }
                NavigationStack { TVSources() }.tabItem { Label("Sources", systemImage: "externaldrive") }
            }
            .environmentObject(store)
            .task { await store.restore() }
            .fullScreenCover(item: $store.playback) { item in
                TVPlaybackScreen(item: item).environmentObject(store)
            }
            .alert("TVBox", isPresented: Binding(get: { store.alert != nil }, set: { if !$0 { store.alert = nil } })) {
                Button("OK", role: .cancel) { store.alert = nil }
            } message: {
                Text(store.alert ?? "")
            }
        }
    }
}

struct TVBrowse: View {
    @EnvironmentObject private var store: TelevisionStore
    @AppStorage("browse.site") private var sourceID = ""
    @State private var films: [VODSearchHit] = []
    @State private var groups: [TVBoxCore.Category] = []
    @State private var category = ""
    @State private var page = 1
    @State private var lastPage = 1
    @State private var loading = false
    @State private var failure: String?
    @State private var retry = 0

    private var source: VODSearchSource? { store.vodSources.first { $0.id == sourceID } ?? store.vodSources.first }

    private struct Request: Hashable {
        let source: VODSearchSource?
        let category: String
        let page: Int
        let retry: Int
    }

    var body: some View {
        let request = Request(source: source, category: category, page: page, retry: retry)
        ScrollView {
            VStack(alignment: .leading, spacing: 30) {
                if let source {
                    HStack {
                        Picker("Video source", selection: Binding(get: { source.id }, set: {
                            sourceID = $0; category = ""; page = 1
                        })) {
                            ForEach(store.vodSources) { Text($0.name).tag($0.id) }
                        }
                        if !groups.isEmpty {
                            Picker("Category", selection: Binding(get: { category }, set: { category = $0; page = 1 })) {
                                Text("All").tag("")
                                ForEach(groups) { Text($0.name).tag($0.id) }
                            }
                        }
                    }
                    if loading { ProgressView() }
                    if let failure {
                        Text(failure)
                        Button("Retry") { retry += 1 }
                    }
                    if films.isEmpty && !loading && failure == nil {
                        Text("No videos found.").foregroundStyle(.secondary)
                    }
                    TVVideoGrid(hits: films)
                    if page < lastPage { Button("Load more") { page += 1 }.disabled(loading) }
                } else if store.restoring {
                    ProgressView("Loading sources…")
                } else {
                    ContentUnavailableView("No video source", systemImage: "film", description: Text("Add a compatible subscription in Sources."))
                    Button("Play a sample video") { playSample() }
                }
            }.padding(.horizontal, 46).padding(.vertical, 24)
        }
        .navigationTitle("Browse")
        .task(id: request) { await load(request) }
    }

    private func load(_ request: Request) async {
        guard let source = request.source else { return }
        loading = true
        failure = nil
        if request.page == 1 { films = []; lastPage = 1 }
        async let categories = request.page == 1 ? (try? store.service.categories(site: source.site)) : nil
        do {
            let result = try await store.service.catalog(site: source.site, category: request.category, page: request.page)
            let videos = await store.service.checkedCatalogVideos(result.videos, site: source.site, availability: store.availability)
            let responseGroups = await categories
            guard !Task.isCancelled else { return }
            if request.page == 1 { groups = responseGroups ?? result.categories }
            var ids = Set(films.map(\.id))
            films += videos.map { VODSearchHit(video: $0, source: source) }.filter { ids.insert($0.id).inserted }
            lastPage = result.pageCount
        } catch {
            guard !Task.isCancelled else { return }
            failure = error.localizedDescription
        }
        loading = false
    }

    private func playSample() {
        guard let video = Demo.videos.first, let line = video.lines.first, let episode = line.episodes.first else { return }
        store.playback = try? TVPlaybackItem.onDemand(nil, title: video.title, line: line, episode: episode)
    }
}

struct TVSearch: View {
    @EnvironmentObject private var store: TelevisionStore
    @State private var query = ""
    @State private var submitted = ""
    @State private var requestID = UUID()
    @State private var hits: [VODSearchHit] = []
    @State private var checking = false
    @State private var completed = 0
    @State private var total = 0
    @State private var failures = 0

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                HStack {
                    TextField("Title", text: $query).onSubmit(submit)
                    Button("Search", action: submit).disabled(query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                if checking { ProgressView("Checking \(completed) of \(total) sources", value: Double(completed), total: Double(max(1, total))) }
                if !submitted.isEmpty && !checking && hits.isEmpty {
                    let message: LocalizedStringKey = total == 0 ? "Add a searchable source in Sources." : "No matching videos found."
                    Text(message).foregroundStyle(.secondary)
                }
                if failures > 0 { Text("\(failures) sources did not respond.").font(.callout).foregroundStyle(.secondary) }
                TVVideoGrid(hits: hits, groupTitles: true)
            }.padding(.horizontal, 46).padding(.vertical, 24)
        }
        .navigationTitle("Search")
        .task(id: requestID) {
            guard !submitted.isEmpty else { return }
            let sources = store.vodSources.filter { $0.site.searchable }
            total = sources.count
            completed = 0; failures = 0; hits = []; checking = !sources.isEmpty
            var seen = Set<String>()
            await store.service.searchAcrossSources(sources, query: submitted, availability: store.availability) { _, results, success in
                guard !Task.isCancelled else { return }
                completed += 1
                if !success { failures += 1 }
                hits += results.filter { seen.insert($0.id).inserted }
            }
            if !Task.isCancelled { checking = false }
        }
    }

    private func submit() {
        submitted = query.trimmingCharacters(in: .whitespacesAndNewlines)
        requestID = UUID()
    }
}

private struct TVVideoGrid: View {
    let hits: [VODSearchHit]
    var groupTitles = false

    private var groups: [[VODSearchHit]] {
        guard groupTitles else { return hits.map { [$0] } }
        let grouped = Dictionary(grouping: hits) { VODMatch.titleKey($0.video) }
        return grouped.keys.sorted().compactMap { grouped[$0] }
    }

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 175, maximum: 250), spacing: 26)], alignment: .leading, spacing: 36) {
            ForEach(groups.map(TVTitleGroup.init)) { group in
                NavigationLink {
                    if group.hits.count == 1 { TVVideoDetail(hit: group.first) }
                    else {
                        List(group.hits) { hit in
                            NavigationLink(hit.source.name) { TVVideoDetail(hit: hit) }
                        }.navigationTitle(group.first.video.title)
                    }
                } label: {
                    VStack(alignment: .leading, spacing: 12) {
                        Color.white.opacity(0.08)
                            .aspectRatio(2.0 / 3, contentMode: .fit)
                            .overlay {
                                if let poster = httpURL(group.first.video.poster) {
                                    AsyncImage(url: poster) { phase in
                                        if let image = phase.image { image.resizable().scaledToFill() }
                                        else { Image(systemName: "film").foregroundStyle(.secondary) }
                                    }
                                } else { Image(systemName: "film").foregroundStyle(.secondary) }
                            }
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                        Text(group.first.video.title).lineLimit(2)
                        if group.hits.count > 1 { Text("\(group.hits.count) sources").font(.caption).foregroundStyle(.secondary) }
                    }
                }.buttonStyle(.card)
            }
        }
    }

    private struct TVTitleGroup: Identifiable {
        let hits: [VODSearchHit]
        var first: VODSearchHit { hits[0] }
        var id: String { first.id }
        init(_ hits: [VODSearchHit]) { self.hits = hits }
    }
}

private struct TVVideoDetail: View {
    @EnvironmentObject private var store: TelevisionStore
    let hit: VODSearchHit
    @State private var detail: VODSearchHit?
    @State private var failure: String?

    var body: some View {
        List {
            if let detail {
                if !detail.video.summary.isEmpty { Text(detail.video.summary).foregroundStyle(.secondary) }
                if detail.video.lines.isEmpty { Text("No playable episodes.") }
                ForEach(detail.video.lines) { line in
                    Section(line.name) {
                        ForEach(line.episodes) { episode in
                            Button(episode.name) {
                                do {
                                    store.playback = try TVPlaybackItem.onDemand(detail, title: detail.video.title,
                                                                                line: line, episode: episode)
                                } catch { store.alert = error.localizedDescription }
                            }
                        }
                    }
                }
            } else if let failure { Text(failure) }
            else { ProgressView("Loading episodes…") }
        }
        .navigationTitle(hit.video.title)
        .task(id: hit.id) {
            do { detail = try await store.detail(hit) }
            catch { if !Task.isCancelled { failure = error.localizedDescription } }
        }
    }
}

struct TVLive: View {
    @EnvironmentObject private var store: TelevisionStore
    @AppStorage("live.feed") private var feedID = ""
    @State private var index = ChannelIndex(channels: [])
    @State private var loading = false
    @State private var failure: String?
    @State private var retry = 0

    private var feed: TVLiveFeed? { store.liveFeeds.first { $0.id == feedID } ?? store.liveFeeds.first }

    var body: some View {
        let active = feed
        List {
            if let active {
                Picker("Live source", selection: Binding(get: { active.id }, set: { feedID = $0 })) {
                    ForEach(store.liveFeeds) { Text($0.name).tag($0.id) }
                }
                if loading { ProgressView("Loading channels…") }
                if let failure {
                    Text(failure)
                    Button("Retry") { retry += 1 }
                }
                ForEach(index.sections(grouping: .original)) { section in
                    Section(section.name) {
                        ForEach(section.channels) { channel in
                            Button(channel.name) {
                                do { store.playback = try TVPlaybackItem.live(channel) }
                                catch { store.alert = error.localizedDescription }
                            }
                        }
                    }
                }
            } else if store.restoring { ProgressView("Loading sources…") }
            else { Text("Add an M3U or TXT playlist in Sources.").foregroundStyle(.secondary) }
        }
        .navigationTitle("Live TV")
        .task(id: (active?.id ?? "") + "|\(retry)") {
            guard let active else { return }
            index = ChannelIndex(channels: [])
            loading = true; failure = nil
            do {
                let channels: [Channel]
                if let feed = active.feed { channels = try await store.service.channels(feed: feed) }
                else { channels = active.channels }
                guard !Task.isCancelled else { return }
                index = ChannelIndex(channels: channels.filter { $0.urls.contains { httpURL($0) != nil } })
                if index.channels.isEmpty { failure = String(localized: "This playlist contains no compatible HTTP streams.") }
            } catch {
                guard !Task.isCancelled else { return }
                failure = error.localizedDescription
            }
            loading = false
        }
    }
}

struct TVHistory: View {
    @EnvironmentObject private var store: TelevisionStore
    @State private var selected: TVBookmark?

    var body: some View {
        List {
            if store.bookmarks.isEmpty { Text("No playback history yet.").foregroundStyle(.secondary) }
            ForEach(store.bookmarks) { bookmark in
                Button {
                    selected = bookmark
                } label: {
                    VStack(alignment: .leading) {
                        Text(bookmark.title)
                        Text("\(bookmark.episode) · \(bookmark.position.formatted(.number.precision(.fractionLength(0)))) s")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                }.disabled(selected != nil || store.restoring)
            }
        }
        .navigationTitle("History")
        .task(id: selected?.id) {
            guard let selected else { return }
            do { try await store.resume(selected) }
            catch { if !Task.isCancelled { store.alert = error.localizedDescription } }
            if !Task.isCancelled { self.selected = nil }
        }
    }
}

struct TVSources: View {
    @EnvironmentObject private var store: TelevisionStore
    @State private var url = ""
    @State private var pending: TVSubscription?
    @State private var removal: TVSubscription?

    var body: some View {
        List {
            Section("Add source") {
                TextField("HTTPS subscription or playlist address", text: $url).onSubmit(add)
                Button("Add", action: add).disabled(url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || pending != nil)
                if pending != nil { ProgressView("Loading source…") }
            }
            ForEach(store.subscriptions) { source in
                Section(source.name) {
                    Text(source.url.host ?? source.name).font(.callout).foregroundStyle(.secondary)
                    Button("Reload source") { pending = source }.disabled(pending != nil)
                    Button("Remove source", role: .destructive) { removal = source }.disabled(pending != nil)
                    if let config = store.configurations[source.url] {
                        ForEach(config.subscriptions) { child in
                            Button(child.name) {
                                if let address = httpURL(child.url) { pending = TVSubscription(url: address, name: child.name) }
                            }.disabled(pending != nil)
                        }
                    }
                }
            }
        }
        .navigationTitle("Sources")
        .confirmationDialog("Remove source?", isPresented: Binding(get: { removal != nil }, set: { if !$0 { removal = nil } }), presenting: removal) { source in
            Button("Remove source", role: .destructive) { store.remove(source); removal = nil }
        }
        .task(id: pending?.id) {
            guard let pending else { return }
            do { try await store.importSource(pending.url.absoluteString, name: pending.name); url = "" }
            catch { if !Task.isCancelled { store.alert = error.localizedDescription } }
            if !Task.isCancelled { self.pending = nil }
        }
    }

    private func add() {
        guard pending == nil else { return }
        guard let address = httpURL(url) else { store.alert = TelevisionError.invalidAddress.localizedDescription; return }
        pending = TVSubscription(url: address, name: "")
    }
}
