import SwiftUI
import TVBoxCore

enum Theme {
    static let background = Color(red: 0.043, green: 0.057, blue: 0.086)
    static let panel = Color(red: 0.075, green: 0.090, blue: 0.125)
    static let muted = Color(red: 0.52, green: 0.57, blue: 0.65)
    static let accent = Color(red: 1, green: 0.54, blue: 0.31)
    static let line = Color.white.opacity(0.075)
}

struct ContentView: View {
    @EnvironmentObject var store: AppStore
    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Rectangle().fill(Theme.line).frame(width: 1)
            VStack(spacing: 0) {
                header
                Rectangle().fill(Theme.line).frame(height: 1)
                if store.playback != nil { PlaybackView() }
                else {
                    switch store.section {
                    case .discover: DiscoverView()
                    case .live: LiveView(browser: store.liveBrowser, probe: store.networkProbe)
                    case .favorites: LibraryView(history: false)
                    case .history: LibraryView(history: true)
                    case .sources: SourcesView(probe: store.networkProbe, browser: store.liveBrowser)
                    case .network: NetworkProbeView(model: store.networkProbe)
                    }
                }
            }
        }
        .background(Theme.background).tint(Theme.accent)
        .sheet(isPresented: $store.importSheet) { ImportView().environmentObject(store) }
        .sheet(isPresented: $store.directSheet) { DirectView().environmentObject(store) }
        .sheet(item: $store.detail) { DetailView(selection: $0).environmentObject(store) }
        .alert("TVBox", isPresented: Binding(get: { store.alert != nil }, set: { if !$0 { store.alert = nil } })) {
            Button("知道了", role: .cancel) { store.alert = nil }
        } message: { Text(store.alert ?? "") }
    }
    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: "play.tv.fill").font(.system(size: 24, weight: .semibold)).foregroundStyle(Theme.accent)
                    .frame(width: 44, height: 44).background(Theme.accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 13))
                VStack(alignment: .leading, spacing: 1) {
                    Text("TVBox").font(.system(size: 23, weight: .bold, design: .rounded))
                    Text("FOR macOS").font(.system(size: 9, weight: .semibold)).tracking(2.7).foregroundStyle(Theme.muted)
                }
            }.padding(.horizontal, 24).padding(.top, 48).padding(.bottom, 42)
            Text("媒体中心").font(.system(size: 10, weight: .medium)).tracking(1.5).foregroundStyle(Theme.muted).padding(.leading, 28).padding(.bottom, 14)
            ForEach(Section.allCases) { section in
                Button {
                    store.section = section
                    if store.playback != nil { store.stop() }
                } label: {
                    HStack(spacing: 13) {
                        Image(systemName: section.icon).font(.system(size: 16)).frame(width: 20)
                        Text(section.rawValue).font(.system(size: 13, weight: store.section == section ? .semibold : .regular))
                        Spacer()
                        if section == .favorites && !store.favorites.isEmpty { Text("\(store.favorites.count)").font(.system(size: 10)).foregroundStyle(Theme.muted) }
                    }
                    .foregroundStyle(store.section == section ? Theme.accent : Color.white.opacity(0.65))
                    .padding(.horizontal, 15).frame(height: 43)
                    .background(store.section == section ? Theme.accent.opacity(0.10) : .clear, in: RoundedRectangle(cornerRadius: 9))
                }.buttonStyle(.plain).padding(.horizontal, 14).padding(.bottom, 5)
            }
            Spacer()
            VStack(alignment: .leading, spacing: 13) {
                HStack(spacing: 7) {
                    Circle().fill(store.hasSources ? Color.green : Theme.muted).frame(width: 5, height: 5)
                    Text(store.hasSources ? "\(store.vodSources.count) 点播 · \(store.liveSources.count) 直播" : "尚未添加内容来源").font(.system(size: 11)).foregroundStyle(Theme.muted)
                }
                Button { store.showImport() } label: {
                    Label("添加内容源", systemImage: "plus").font(.system(size: 12, weight: .medium)).frame(maxWidth: .infinity).padding(.vertical, 10)
                }.buttonStyle(.plain).background(Color.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 8)).overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.line))
                Text("你的片源，你的影院。").font(.system(size: 10)).foregroundStyle(Theme.muted.opacity(0.7)).frame(maxWidth: .infinity)
            }.padding(22)
        }.frame(width: 214).background(Color.black.opacity(0.12))
    }
    private var header: some View {
        HStack(spacing: 14) {
            Text(store.playback == nil ? store.section.rawValue : "正在播放").font(.system(size: 14, weight: .semibold))
            if store.playback == nil && store.section == .discover {
                Text(store.isDemo ? "开放电影演示" : (store.site?.name ?? "请选择影视源"))
                    .font(.system(size: 10)).foregroundStyle(Theme.muted).padding(.horizontal, 9).padding(.vertical, 5).background(Theme.panel, in: Capsule())
            }
            Spacer()
            Button { store.directSheet = true } label: { Label("打开视频", systemImage: "link").font(.system(size: 12)) }.buttonStyle(.plain).foregroundStyle(Theme.muted)
            Rectangle().fill(Theme.line).frame(width: 1, height: 16).padding(.horizontal, 6)
            Image(systemName: "desktopcomputer").foregroundStyle(Theme.accent).font(.system(size: 15))
        }.padding(.horizontal, 32).frame(height: 75)
    }
}

struct DiscoverView: View {
    @EnvironmentObject var store: AppStore
    private let columns = [GridItem(.adaptive(minimum: 155, maximum: 210), spacing: 20)]
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 25) {
                hero
                if !store.vodSources.isEmpty {
                    HStack(spacing: 12) {
                        Label("点播源", systemImage: "externaldrive").font(.system(size: 12)).foregroundStyle(Theme.muted)
                        Picker("点播源", selection: Binding(get: { store.sourceLibrary.selectedVODID ?? "" }, set: { store.selectVODSource($0) })) {
                            ForEach(store.vodSources) { Text($0.name).tag($0.id) }
                        }.labelsHidden().frame(maxWidth: 300)
                        Spacer()
                        Button { store.showImport(.vod) } label: { Label("添加点播源", systemImage: "plus") }.font(.system(size: 12)).buttonStyle(.borderless)
                    }
                }
                HStack(spacing: 12) {
                    Text(store.submittedQuery.isEmpty ? "探索片库" : "搜索结果").font(.system(size: 21, weight: .semibold))
                    if !store.supportedSites.isEmpty {
                        Picker("影视源", selection: Binding(get: { store.siteID }, set: { store.selectSite($0) })) {
                            ForEach(store.supportedSites) { Text($0.name).tag($0.id) }
                        }.labelsHidden().frame(maxWidth: 190)
                    }
                    Spacer()
                    HStack(spacing: 8) {
                        Image(systemName: "magnifyingglass").foregroundStyle(Theme.muted)
                        TextField("搜索当前影视源", text: $store.query).textFieldStyle(.plain).onSubmit { store.search() }
                        if !store.query.isEmpty { Button { store.query = ""; store.search() } label: { Image(systemName: "xmark.circle.fill") }.buttonStyle(.plain).foregroundStyle(Theme.muted) }
                    }.font(.system(size: 12)).padding(11).frame(width: 225).background(Theme.panel, in: RoundedRectangle(cornerRadius: 9))
                    .disabled(store.site?.searchable == false)
                }
                if !store.categories.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            categoryButton("全部", id: "")
                            ForEach(store.categories) { categoryButton($0.name, id: $0.id) }
                        }
                    }
                }
                if let error = store.catalogError { ErrorBanner(message: error) { store.refresh() } }
                if store.loading && store.videos.isEmpty {
                    ProgressView("正在加载影视源…").frame(maxWidth: .infinity).padding(70)
                } else if !store.isDemo && store.supportedSites.isEmpty {
                    EmptyViewCard(icon: "puzzlepiece.extension", title: "这个配置需要爬虫运行时", message: "当前版本支持 type 0 XML 和 type 1 JSON 接口。可以在配置管理中查看兼容情况，或导入其他接口。", action: "查看配置") { store.section = .sources }
                } else if store.videos.isEmpty && store.catalogError == nil {
                    EmptyViewCard(icon: "magnifyingglass", title: "没有找到影片", message: "试试其他关键词、分类或影视源。")
                } else {
                    LazyVGrid(columns: columns, alignment: .leading, spacing: 25) {
                        ForEach(Array(store.videos.enumerated()), id: \.element.id) { index, video in
                            VideoCard(video: video, index: index) { store.show(video, site: store.site) }
                        }
                    }
                    if store.page < store.pageCount {
                        HStack { Spacer(); Button(store.loading ? "加载中…" : "加载更多 · \(store.page) / \(store.pageCount)") { store.refresh(append: true) }.disabled(store.loading); Spacer() }.padding(.top, 12)
                    }
                }
                HStack(spacing: 5) {
                    Image(systemName: "info.circle")
                    Text(store.isDemo ? "演示内容来自 Blender 开放电影。导入配置后，这里将显示你的片库。" : "内容由当前配置提供，播放能力取决于片源格式与连接情况。")
                }.font(.system(size: 10)).foregroundStyle(Theme.muted).padding(.top, 8)
            }.padding(32)
        }
    }
    private func categoryButton(_ name: String, id: String) -> some View {
        Button { store.selectCategory(id) } label: {
            Text(name).font(.system(size: 12, weight: .medium)).padding(.horizontal, 15).padding(.vertical, 8)
                .foregroundStyle(store.category == id ? Theme.accent : Theme.muted)
                .background(store.category == id ? Theme.accent.opacity(0.12) : Theme.panel, in: Capsule())
        }.buttonStyle(.plain)
    }
    private var hero: some View {
        ZStack(alignment: .leading) {
            LinearGradient(colors: [Color(red: 0.18, green: 0.22, blue: 0.30), Color(red: 0.10, green: 0.13, blue: 0.20), Color(red: 0.17, green: 0.12, blue: 0.13)], startPoint: .topLeading, endPoint: .bottomTrailing)
            GeometryReader { proxy in
                ZStack {
                    ForEach(0..<5) { index in
                        Circle().stroke(Theme.accent.opacity(0.07 + Double(index) * 0.018), lineWidth: 1).frame(width: CGFloat(130 + index * 62), height: CGFloat(130 + index * 62))
                    }
                    Image(systemName: "play.rectangle.fill").font(.system(size: 100, weight: .ultraLight)).foregroundStyle(Theme.accent.opacity(0.8)).rotationEffect(.degrees(-8))
                }.position(x: proxy.size.width * 0.80, y: proxy.size.height * 0.50)
            }.clipped()
            VStack(alignment: .leading, spacing: 15) {
                HStack(spacing: 7) { Rectangle().fill(Theme.accent).frame(width: 17, height: 2); Text("YOUR PERSONAL CINEMA").font(.system(size: 9, weight: .semibold)).tracking(2.8).foregroundStyle(Theme.accent) }
                Text(store.isDemo ? "让好故事，\n在 Mac 上开场。" : "坐下来，\n发现下一部好片。")
                    .font(.system(size: 33, weight: .semibold)).lineSpacing(5)
                Text(store.isDemo ? "导入你的 TVBox 配置，连接专属片库。" : "\(store.selectedVODSource?.name ?? "个人片库") · 影视 / 直播 / 收藏")
                    .font(.system(size: 12)).foregroundStyle(Color.white.opacity(0.53))
                HStack(spacing: 12) {
                    Button { store.showImport(.vod) } label: { Label("添加点播源", systemImage: "plus").font(.system(size: 12, weight: .semibold)).padding(.horizontal, 17).padding(.vertical, 11) }.buttonStyle(.plain).foregroundStyle(Color.black.opacity(0.85)).background(Theme.accent, in: RoundedRectangle(cornerRadius: 8))
                    Button { store.directSheet = true } label: { Label("播放直链", systemImage: "play.fill").font(.system(size: 12)).padding(.horizontal, 12).padding(.vertical, 11) }.buttonStyle(.plain).foregroundStyle(Color.white.opacity(0.8))
                }.padding(.top, 5)
            }.padding(30)
        }.frame(height: 270).clipShape(RoundedRectangle(cornerRadius: 16)).overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.white.opacity(0.06)))
    }
}

struct VideoCard: View {
    let video: Video
    var index: Int = 0
    var footnote: String? = nil
    let action: () -> Void
    @State private var hovered = false
    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 10) {
                ZStack(alignment: .bottomLeading) {
                    PosterView(video: video, index: index).aspectRatio(0.70, contentMode: .fit)
                    LinearGradient(colors: [.clear, .black.opacity(0.8)], startPoint: .center, endPoint: .bottom)
                    if !video.note.isEmpty { Text(video.note).font(.system(size: 10, weight: .medium)).lineLimit(1).padding(12).foregroundStyle(.white.opacity(0.9)) }
                    if hovered {
                        Color.black.opacity(0.22)
                        Image(systemName: "play.circle.fill").font(.system(size: 45)).foregroundStyle(.white).frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }.clipShape(RoundedRectangle(cornerRadius: 11)).overlay(RoundedRectangle(cornerRadius: 11).stroke(hovered ? Theme.accent.opacity(0.7) : Theme.line))
                Text(video.title).font(.system(size: 13, weight: .medium)).lineLimit(1).foregroundStyle(.white.opacity(0.9))
                Text(footnote ?? [video.year, video.area].filter { !$0.isEmpty }.joined(separator: " · ")).font(.system(size: 10)).foregroundStyle(Theme.muted).lineLimit(1)
            }.contentShape(Rectangle())
        }.buttonStyle(.plain).onHover { hovered = $0 }
    }
}

struct PosterView: View {
    let video: Video
    var index: Int = 0
    private var colors: [Color] {
        let palette: [[Color]] = [[Color(red: 0.18, green: 0.39, blue: 0.34), Color(red: 0.05, green: 0.14, blue: 0.14)], [Color(red: 0.43, green: 0.25, blue: 0.24), Color(red: 0.14, green: 0.09, blue: 0.16)], [.indigo.opacity(0.7), Theme.panel], [.brown, Theme.panel]]
        return palette[index % palette.count]
    }
    var body: some View {
        AsyncImage(url: URL(string: video.poster)) { image in image.resizable().scaledToFill() } placeholder: {
            ZStack {
                LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing)
                GeometryReader { geometry in
                    Circle().stroke(.white.opacity(0.08), lineWidth: 1).frame(width: geometry.size.width * 1.2).offset(x: geometry.size.width * 0.10, y: geometry.size.height * 0.18)
                    Circle().fill(.white.opacity(0.04)).frame(width: geometry.size.width * 0.8).offset(x: geometry.size.width * 0.35, y: geometry.size.height * 0.35)
                }
                VStack(alignment: .leading, spacing: 12) {
                    Text(video.year.isEmpty ? "TVBOX" : video.year).font(.system(size: 10, weight: .medium, design: .monospaced)).tracking(3).foregroundStyle(.white.opacity(0.5))
                    Spacer()
                    Image(systemName: index % 2 == 0 ? "film" : "sparkles").font(.system(size: 35, weight: .ultraLight)).foregroundStyle(.white.opacity(0.6))
                    Text(video.title).font(.system(size: 24, weight: .semibold, design: .serif)).foregroundStyle(.white.opacity(0.9)).lineLimit(3)
                    Rectangle().fill(Theme.accent.opacity(0.7)).frame(width: 25, height: 2)
                    Spacer().frame(height: 25)
                }.padding(20)
            }
        }.clipped()
    }
}

struct EmptyViewCard: View {
    let icon: String
    let title: String
    let message: String
    var action: String? = nil
    var perform: (() -> Void)? = nil
    var body: some View {
        VStack(spacing: 15) {
            Image(systemName: icon).font(.system(size: 35, weight: .light)).foregroundStyle(Theme.accent.opacity(0.7)).padding(.bottom, 4)
            Text(title).font(.system(size: 18, weight: .semibold))
            Text(message).font(.system(size: 12)).foregroundStyle(Theme.muted).multilineTextAlignment(.center).lineSpacing(5).frame(maxWidth: 440)
            if let action, let perform { Button(action, action: perform).buttonStyle(.borderedProminent).padding(.top, 4) }
        }.frame(maxWidth: .infinity).padding(.vertical, 65)
    }
}

struct ErrorBanner: View {
    let message: String
    var retry: (() -> Void)? = nil
    var body: some View {
        HStack(alignment: .top, spacing: 11) {
            Image(systemName: "exclamationmark.triangle").foregroundStyle(Theme.accent)
            Text(message).font(.system(size: 12)).foregroundStyle(.white.opacity(0.7)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
            if let retry { Button("重试", action: retry).buttonStyle(.plain).foregroundStyle(Theme.accent).font(.system(size: 12)) }
        }.padding(16).background(Theme.accent.opacity(0.08), in: RoundedRectangle(cornerRadius: 9))
    }
}

struct LibraryView: View {
    @EnvironmentObject var store: AppStore
    var history: Bool
    @State private var confirmClear = false
    private var entries: [LibraryEntry] { history ? store.history : store.favorites }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 25) {
                HStack {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(history ? "继续你的故事" : "留住值得看的").font(.system(size: 27, weight: .semibold))
                        Text(history ? "自动记录播放进度，下次接着看。" : "喜欢的影片，都在这里。").font(.system(size: 12)).foregroundStyle(Theme.muted)
                    }
                    Spacer()
                    if history && !entries.isEmpty { Button("清空记录", role: .destructive) { confirmClear = true }.buttonStyle(.borderless).foregroundStyle(Theme.muted) }
                }
                if entries.isEmpty {
                    EmptyViewCard(icon: history ? "clock" : "heart", title: history ? "还没有播放记录" : "片单等你来填满", message: history ? "播放一部影片，进度会自动保存在本机。" : "在影片详情中点击收藏，就能在这里快速找到。", action: "去发现") { store.section = .discover }
                } else {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 155, maximum: 210), spacing: 20)], alignment: .leading, spacing: 25) {
                        ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                            VideoCard(video: entry.video, index: index, footnote: history ? "\(entry.episode?.name ?? "") · \(formatTime(entry.position))" : entry.site?.name ?? "视频直链 / 演示") { store.show(entry.video, site: entry.site, resume: history ? entry : nil) }
                                .contextMenu {
                                    Button(history ? "从记录中打开" : "查看详情") { store.show(entry.video, site: entry.site, resume: history ? entry : nil) }
                                    if !history { Button("取消收藏", role: .destructive) { store.toggleFavorite(entry.video, site: entry.site) } }
                                }
                        }
                    }
                }
            }.padding(32)
        }.confirmationDialog("清空所有播放记录？", isPresented: $confirmClear) { Button("清空记录", role: .destructive) { store.clearHistory() }; Button("取消", role: .cancel) {} }
    }
}

func formatTime(_ seconds: Double) -> String {
    guard seconds.isFinite, seconds >= 0 else { return "00:00" }
    let value = Int(min(seconds, 360000)); return String(format: "%02d:%02d", value / 60, value % 60)
}
