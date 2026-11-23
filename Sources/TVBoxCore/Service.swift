import Foundation

public struct TVService {
    private let session: URLSession
    private let csp: (any CSPTransport)?
    public init(session: URLSession = .shared, csp: (any CSPTransport)? = nil) { self.session = session; self.csp = csp }
    public func supports(_ site: Site) -> Bool { site.supported || (site.type == 3 && site.csp != nil && csp != nil) }
    private func spider(_ site: Site, _ command: CSPCommand, _ arguments: [String: String] = [:]) async throws -> Data {
        guard site.type == 3, site.csp != nil else { throw TVError.message("此 CSP 接口缺少有效的爬虫组件信息，请刷新配置。") }
        guard let csp else { throw TVError.message("爬虫运行组件尚未就绪，请在配置管理中检查运行环境。") }
        try Task.checkCancellation()
        let data = try await csp.invoke(site: site, command: command, arguments: arguments)
        try Task.checkCancellation()
        guard data.count <= 8 * 1024 * 1024 else { throw TVError.message("爬虫接口返回的数据过大。") }
        return data
    }
    public func data(at url: URL, headers: [String: String] = [:], reload: Bool = false, timeout: TimeInterval = 25) async throws -> Data {
        if url.isFileURL { return try Data(contentsOf: url) }
        guard ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { throw TVError.message("该地址协议暂不支持。请使用 HTTP 或 HTTPS。") }
        var request = URLRequest(url: url, timeoutInterval: timeout)
        if reload {
            request.cachePolicy = .reloadIgnoringLocalCacheData
            request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
            request.setValue("no-cache", forHTTPHeaderField: "Pragma")
        }
        request.setValue("TVBoxMac/1.0", forHTTPHeaderField: "User-Agent")
        headers.forEach { request.setValue($1, forHTTPHeaderField: $0) }
        let (data, response) = try await response(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) { throw TVError.message("服务器返回 HTTP \(http.statusCode)。请检查配置地址或接口权限。") }
        guard data.count < 16 * 1024 * 1024 else { throw TVError.message("配置或接口响应超过 16 MB。") }
        return data
    }
    private func response(for request: URLRequest) async throws -> (Data, URLResponse) {
        for attempt in 0...1 {
            try Task.checkCancellation()
            do { return try await session.data(for: request) }
            catch {
                try Task.checkCancellation()
                let failure = PlaybackFailure(error: error)
                if failure.kind == .tls && attempt == 0 {
                    try await Task.sleep(nanoseconds: 700_000_000)
                    continue
                }
                if attempt == 1 {
                    let message = failure.kind == .tls
                        ? "仍无法与服务器建立安全连接。请稍后再试，或更换配置地址 / 接口；如果一直出现，请联系来源提供者。"
                        : "仍未能获取数据。请检查网络，稍后重试，或更换配置地址 / 接口。"
                    throw TVError.message("已自动重试 1 次，" + message)
                }
                if failure.kind == .certificate { throw TVError.message(failure.message) }
                throw error
            }
        }
        throw TVError.message("暂时无法连接服务器，请稍后重试。")
    }
    public func configuration(at url: URL, reload: Bool = false) async throws -> Configuration { try Parser.configuration(await data(at: url, reload: reload), base: url) }

    /// A checksum change can mean the saved subscription is older than its
    /// unversioned JAR. Refresh that subscription once, never trust the observed
    /// hash as a replacement, and return staged metadata only after success.
    public func catalogRefreshingCSP(source: SavedVODSource, siteID: String, category: String?, search: String, page: Int) async throws -> (catalog: Catalog, categories: [Category]?, refreshed: SavedVODSource?) {
        guard let site = source.runtimeSite(siteID) else { throw CSPFailure.interfaceChanged }
        func load(_ site: Site) async throws -> (Catalog, [Category]?) {
            async let groups = try? categories(site: site)
            let result = try await catalog(site: site, category: category, search: search, page: page)
            return (result, await groups)
        }
        do {
            let result = try await load(site)
            return (result.0, result.1, nil)
        } catch CSPFailure.componentChecksumMismatch {
            try Task.checkCancellation()
            if source.componentOverrides?[siteID]?.api == site.api { throw CSPFailure.localComponentMismatch }
            guard let origin = URL(string: source.origin), ["http", "https", "file"].contains(origin.scheme ?? ""), site.csp?.configurationURL == origin else {
                throw CSPFailure.interfaceChanged
            }
            let fresh = try source.refreshingCSP(await configuration(at: origin, reload: true), siteID: siteID)
            try Task.checkCancellation()
            guard let candidate = fresh.runtimeSite(siteID) else { throw CSPFailure.interfaceChanged }
            do {
                let result = try await load(candidate)
                return (result.0, result.1, fresh)
            } catch CSPFailure.componentChecksumMismatch { throw CSPFailure.refreshedChecksumMismatch }
        }
    }
    public func channels(feed: LiveFeed) async throws -> [Channel] {
        guard let url = URL(string: feed.url) else { throw TVError.message("直播订阅地址无效。") }
        let bytes = try ConfigurationPayload.decode(await data(at: url, headers: feed.headers))
        guard let text = String(data: bytes, encoding: .utf8) else { throw TVError.message("直播列表必须使用 UTF-8 编码。") }
        let list = Parser.playlist(text, base: url, headers: feed.headers, guide: feed.guide)
        guard !list.isEmpty else { throw TVError.message("直播订阅未包含可识别的频道。") }
        return list
    }
    public func requestURL(site: Site, parameters: [String: String]) throws -> URL {
        guard site.supported else { throw TVError.message("此源需要 Android 爬虫运行时。当前支持 type 0 XML 和 type 1 JSON 采集接口。") }
        guard var components = URLComponents(string: site.api) else { throw TVError.message("影视源地址无效。") }
        var items = (components.queryItems ?? []).filter { parameters[$0.name] == nil }
        items.append(contentsOf: parameters.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) })
        components.queryItems = items
        guard let url = components.url else { throw TVError.message("无法生成请求地址。") }; return url
    }
    public func catalog(site: Site, category: String? = nil, search: String = "", page: Int = 1, timeout: TimeInterval = 25) async throws -> Catalog {
        if site.type == 3 {
            let command: CSPCommand = !search.isEmpty ? .search : !(category ?? "").isEmpty ? .category : .home
            let bytes = try await spider(site, command, ["category": category ?? "", "query": search, "page": String(max(1, page))])
            let catalog = try Parser.catalog(bytes, base: site.csp?.configurationURL, resolveEpisodeURLs: false)
            if command == .home && catalog.videos.isEmpty {
                var fallback = catalog
                do { fallback = try Parser.catalog(await spider(site, .homeVideo), base: site.csp?.configurationURL, resolveEpisodeURLs: false) }
                catch { if catalog.categories.isEmpty { throw error } }
                if fallback.categories.isEmpty { fallback.categories = catalog.categories }
                if fallback.videos.isEmpty, let first = fallback.categories.first {
                    var listing = try Parser.catalog(await spider(site, .category, ["category": first.id, "page": String(max(1, page))]), base: site.csp?.configurationURL, resolveEpisodeURLs: false)
                    listing.categories = fallback.categories
                    return listing
                }
                return fallback
            }
            return catalog
        }
        var parameters = ["ac": site.type == 0 ? "videolist" : "detail", "pg": String(page)]
        if let category, !category.isEmpty { parameters["t"] = category }
        if !search.isEmpty { parameters["wd"] = search }
        let url = try requestURL(site: site, parameters: parameters)
        return try Parser.catalog(await data(at: url, headers: site.headers, timeout: timeout), base: url)
    }
    public func categories(site: Site) async throws -> [Category] {
        if site.type == 3 {
            return try Parser.catalog(await spider(site, .home), base: site.csp?.configurationURL, resolveEpisodeURLs: false).categories
        }
        let url = try requestURL(site: site, parameters: ["ac": "list"])
        return try Parser.catalog(await data(at: url, headers: site.headers), base: url).categories
    }
    public func detail(video: Video, site: Site, timeout: TimeInterval = 25) async throws -> Video {
        if site.type == 3 {
            let bytes = try await spider(site, .detail, ["id": video.id])
            guard let detail = try Parser.catalog(bytes, base: site.csp?.configurationURL, resolveEpisodeURLs: false).videos.first else { throw TVError.message("爬虫未返回这部影片的详情。") }
            return detail
        }
        let url = try requestURL(site: site, parameters: ["ac": site.type == 0 ? "videolist" : "detail", "ids": video.id])
        guard let detail = try Parser.catalog(await data(at: url, headers: site.headers, timeout: timeout), base: url).videos.first else { throw TVError.message("接口未返回这部影片的详情。") }
        return detail
    }
    public func checkedCatalogVideos(_ videos: [Video], site: Site?, availability: VODAvailability, probeLimit: Int = 8) async -> [Video] {
        var candidates = videos
        if let site, site.supported, probeLimit > 0 {
            let ids = videos.lazy.filter { $0.lines.isEmpty && !$0.id.contains(",") }.prefix(probeLimit).map(\.id)
            if !ids.isEmpty,
               let url = try? requestURL(site: site, parameters: ["ac": site.type == 0 ? "videolist" : "detail", "ids": ids.joined(separator: ",")]),
               let bytes = try? await data(at: url, headers: site.headers, timeout: 2.5),
               let detail = try? Parser.catalog(bytes, base: url) {
                let requested = Set(ids)
                let lines = Dictionary(detail.videos.filter { requested.contains($0.id) && !$0.lines.isEmpty }
                    .map { ($0.id, $0.lines) }, uniquingKeysWith: { first, _ in first })
                for index in candidates.indices where candidates[index].lines.isEmpty {
                    if let resolved = lines[candidates[index].id] { candidates[index].lines = resolved }
                }
            }
        }
        let checked = await availability.filter(candidates, site: site, probeLimit: probeLimit)
        let summaries = Set(videos.filter { $0.lines.isEmpty }.map(\.id))
        // Keep catalog summaries as summaries so opening one still loads full details.
        return checked.map { video in
            guard summaries.contains(video.id) else { return video }
            var summary = video
            summary.lines = []
            return summary
        }
    }
    public func resolvePlayback(site: Site, line: PlayLine, episode: Episode) async throws -> CSPPlayback {
        if site.type == 3 {
            guard let csp, site.csp != nil else { throw TVError.message("爬虫运行组件尚未就绪，请重试。") }
            return try await csp.playback(site: site, arguments: ["flag": line.name, "id": episode.url])
        }
        return try CSPPlayback(data: JSONSerialization.data(withJSONObject: ["url": episode.url, "parse": 0]), headers: site.headers)
    }
}
