import Foundation

public struct TVService {
    private let session: URLSession
    public init(session: URLSession = .shared) { self.session = session }
    public func data(at url: URL, headers: [String: String] = [:]) async throws -> Data {
        if url.isFileURL { return try Data(contentsOf: url) }
        guard ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { throw TVError.message("该地址协议暂不支持。请使用 HTTP 或 HTTPS。") }
        var request = URLRequest(url: url, timeoutInterval: 25)
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
    public func configuration(at url: URL) async throws -> Configuration { try Parser.configuration(await data(at: url), base: url) }
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
    public func catalog(site: Site, category: String? = nil, search: String = "", page: Int = 1) async throws -> Catalog {
        var parameters = ["ac": site.type == 0 ? "videolist" : "detail", "pg": String(page)]
        if let category, !category.isEmpty { parameters["t"] = category }
        if !search.isEmpty { parameters["wd"] = search }
        let url = try requestURL(site: site, parameters: parameters)
        return try Parser.catalog(await data(at: url, headers: site.headers), base: url)
    }
    public func categories(site: Site) async throws -> [Category] {
        let url = try requestURL(site: site, parameters: ["ac": "list"])
        return try Parser.catalog(await data(at: url, headers: site.headers), base: url).categories
    }
    public func detail(video: Video, site: Site) async throws -> Video {
        let url = try requestURL(site: site, parameters: ["ac": site.type == 0 ? "videolist" : "detail", "ids": video.id])
        guard let detail = try Parser.catalog(await data(at: url, headers: site.headers), base: url).videos.first else { throw TVError.message("接口未返回这部影片的详情。") }
        return detail
    }
}
