import Foundation

/// Legacy URL-based AirPlay video. Discovery and authentication remain explicit:
/// a receiver's 401/403 is an error, never a reason to bypass pairing.
public enum AirPlayVideoProtocol {
    public static let serviceType = "urn:tvboxmac:airplay-video:1"
    public static func features(_ text: String) -> UInt64? {
        let parts = text.split(separator: ",", omittingEmptySubsequences: false)
        guard (1...2).contains(parts.count), parts.allSatisfy({ $0.hasPrefix("0x") && $0.count > 2 && $0.count <= 10 }),
              let low = UInt32(parts[0].dropFirst(2), radix: 16) else { return nil }
        if parts.count == 1 { return UInt64(low) }
        guard let high = UInt32(parts[1].dropFirst(2), radix: 16) else { return nil }
        return UInt64(high) << 32 | UInt64(low)
    }
    public static func device(name: String, id: String, address: String, port: Int, features: String, passwordRequired: Bool) throws -> DLNADevice {
        guard let flags = self.features(features), flags & 1 != 0, LANIPv4.isLocal(address), (1...65535).contains(port) else {
            throw TVError.message("电视未提供可用的 AirPlay 视频兼容接口。")
        }
        guard !passwordRequired else { throw TVError.message("此电视需要 AirPlay 配对或密码，请使用系统 AirPlay 入口完成授权。") }
        guard let base = URL(string: "http://\(address):\(port)/") else { throw TVError.message("电视地址无效。") }
        let transport = DLNAService(type: serviceType, controlURL: base, actions: ["Play", "Pause", "Stop", "Seek"])
        return DLNADevice(id: "airplay-video:" + id, name: name, descriptionURL: base.appendingPathComponent("server-info"), transport: transport)
    }
}

public extension DLNADevice {
    /// The shared casting coordinator uses a transport adapter for URL AirPlay.
    var isAirPlayVideo: Bool { transport.type == AirPlayVideoProtocol.serviceType }
}

public struct AirPlayVideoState: Equatable, Sendable {
    public var ready: Bool
    public var position: Double?
    public var duration: Double?
    public var rate: Double
    public init(data: Data) throws {
        guard data.count <= 1024 * 1024,
              let values = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
            throw TVError.message("电视返回的 AirPlay 播放状态无效。")
        }
        if values["error"] != nil { throw TVError.message("电视报告 AirPlay 视频播放失败。请更换片源或使用 DLNA。") }
        func number(_ key: String) -> Double? {
            guard let n = (values[key] as? NSNumber)?.doubleValue, n.isFinite, n >= 0 else { return nil }; return n
        }
        position = number("position"); duration = number("duration"); rate = number("rate") ?? 0
        ready = (values["readyToPlay"] as? NSNumber)?.boolValue ?? (duration != nil)
    }
}

private final class AirPlayVideoRedirectPolicy: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}

public struct AirPlayVideoClient: Sendable {
    private let session: URLSession
    public init(session: URLSession? = nil) {
        if let session { self.session = session }
        else {
            let config = URLSessionConfiguration.ephemeral
            config.timeoutIntervalForRequest = 5; config.timeoutIntervalForResource = 8
            config.connectionProxyDictionary = [:]; config.urlCache = nil
            self.session = URLSession(configuration: config, delegate: AirPlayVideoRedirectPolicy(), delegateQueue: nil)
        }
    }
    private func send(_ path: String, to endpoint: URL, method: String = "GET", body: Data? = nil, query: [URLQueryItem] = []) async throws -> Data {
        guard endpoint.scheme == "http", let host = endpoint.host, LANIPv4.isLocal(host), endpoint.user == nil, endpoint.password == nil,
              var url = URLComponents(url: endpoint, resolvingAgainstBaseURL: false) else { throw TVError.message("AirPlay 兼容连接需要电视的局域网地址。") }
        url.path = path; url.queryItems = query.isEmpty ? nil : query; url.fragment = nil
        guard let target = url.url else { throw TVError.message("AirPlay 控制地址无效。") }
        var request = URLRequest(url: target); request.httpMethod = method; request.httpBody = body
        request.setValue("MediaControl/1.0", forHTTPHeaderField: "User-Agent")
        if body != nil { request.setValue("application/x-apple-binary-plist", forHTTPHeaderField: "Content-Type") }
        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse, http.url == target else { throw TVError.message("电视返回了无效的 AirPlay 控制响应。") }
        if [401, 403].contains(http.statusCode) { throw TVError.message("电视拒绝 AirPlay 授权。请在电视上完成配对，或使用系统 AirPlay / DLNA。") }
        if [404, 405, 501].contains(http.statusCode) { throw DLNAFault(401) }
        guard (200..<300).contains(http.statusCode) else { throw TVError.message("电视未能完成 AirPlay 操作。（HTTP \(http.statusCode)）") }
        var data = Data()
        for try await byte in bytes { guard data.count < 1024 * 1024 else { throw TVError.message("电视返回的 AirPlay 数据过大。") }; data.append(byte) }
        return data
    }
    public func play(_ media: URL, on endpoint: URL) async throws {
        guard media.scheme == "http", let host = media.host, LANIPv4.isLocal(host), media.user == nil, media.password == nil else {
            throw TVError.message("AirPlay 视频需要通过本机临时服务提供。")
        }
        let body = try PropertyListSerialization.data(fromPropertyList: ["Content-Location": media.absoluteString, "Start-Position": 0.0, "X-Apple-Session-ID": UUID().uuidString], format: .binary, options: 0)
        // Cancelling the UI task must not let Stop overtake an already accepted
        // Play on another socket. Await the bounded response; the coordinator
        // then stops a cancelled attempt before a new cast can begin.
        let client = self
        try await Task.detached { _ = try await client.send("/play", to: endpoint, method: "POST", body: body) }.value
    }
    public func state(on endpoint: URL) async throws -> AirPlayVideoState {
        let data = try await send("/playback-info", to: endpoint); return try AirPlayVideoState(data: data)
    }
    public func stop(on endpoint: URL) async throws { _ = try await send("/stop", to: endpoint, method: "POST", body: Data()) }
    public func rate(_ value: Double, on endpoint: URL) async throws {
        guard value == 0 || value == 1 else { throw TVError.message("AirPlay 电视投屏仅支持正常速度与暂停。") }
        _ = try await send("/rate", to: endpoint, method: "POST", body: Data(), query: [URLQueryItem(name: "value", value: String(value))])
    }
    public func seek(_ seconds: Double, on endpoint: URL) async throws {
        guard seconds.isFinite, seconds >= 0 else { throw TVError.message("播放进度无效。") }
        _ = try await send("/scrub", to: endpoint, method: "POST", body: Data(), query: [URLQueryItem(name: "position", value: String(seconds))])
    }
    /// Adapt the existing transport controls without sending SOAP to AirPlay.
    public func action(_ name: String, endpoint: URL, arguments: [(String, String)]) async throws -> [String: String] {
        switch name {
        case "Play": try await rate(1, on: endpoint)
        case "Pause": try await rate(0, on: endpoint)
        case "Stop": try await stop(on: endpoint)
        case "Seek": try await seek(DLNAProtocol.seconds(arguments.first { $0.0 == "Target" }?.1), on: endpoint)
        case "GetTransportInfo":
            let s = try await state(on: endpoint)
            return ["CurrentTransportState": !s.ready ? "STOPPED" : s.rate > 0 ? "PLAYING" : "PAUSED_PLAYBACK", "CurrentTransportStatus": "OK"]
        case "GetPositionInfo":
            let s = try await state(on: endpoint); var result: [String: String] = [:]
            if let p = s.position { result["RelTime"] = DLNAProtocol.time(p) }; if let d = s.duration { result["TrackDuration"] = DLNAProtocol.time(d) }
            return result
        default: throw DLNAFault(401)
        }
        return [:]
    }
}
