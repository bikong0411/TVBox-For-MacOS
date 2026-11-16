import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif

public struct DLNAService: Equatable, Sendable {
    public var type: String
    public var controlURL: URL
    public var descriptionURL: URL?
    public var actions: Set<String> = []
    public init(type: String, controlURL: URL, descriptionURL: URL? = nil, actions: Set<String> = []) {
        self.type = type; self.controlURL = controlURL; self.descriptionURL = descriptionURL; self.actions = actions
    }
}

public struct DLNADevice: Identifiable, Equatable, Sendable {
    public var id: String
    public var name: String
    public var descriptionURL: URL
    public var transport: DLNAService
    public var rendering: DLNAService?
    public init(id: String, name: String, descriptionURL: URL, transport: DLNAService, rendering: DLNAService? = nil) {
        self.id = id; self.name = name; self.descriptionURL = descriptionURL; self.transport = transport; self.rendering = rendering
    }
}

public struct DLNAFault: LocalizedError, Sendable {
    public var code: Int
    public init(_ code: Int) { self.code = code }
    public var errorDescription: String? {
        switch code {
        case 401, 602: return "电视不支持这项播放操作。"
        case 701: return "电视当前状态不允许这项操作，请稍后重试。"
        case 710, 711: return "电视暂不支持跳转到这个位置。"
        case 714, 716: return "电视无法打开这个视频，可能是格式不支持或片源无法访问。"
        default: return "电视未能完成操作，请重试或换一个视频。（设备代码 \(code)）"
        }
    }
}

/// A small, namespace-independent XML tree. External entities are never read.
public final class DLNAXMLNode {
    public let name: String
    public var text = ""
    public var children: [DLNAXMLNode] = []
    init(_ name: String) { self.name = name }
    public func child(_ name: String) -> DLNAXMLNode? { children.first { $0.name == name } }
    public func value(_ name: String) -> String { child(name)?.text.trimmingCharacters(in: .whitespacesAndNewlines) ?? "" }
    public func descendants(_ name: String) -> [DLNAXMLNode] {
        (self.name == name ? [self] : []) + children.flatMap { $0.descendants(name) }
    }
}

private final class DLNAXMLReader: NSObject, XMLParserDelegate {
    var root: DLNAXMLNode?
    var stack: [DLNAXMLNode] = []
    var count = 0
    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String]) {
        count += 1
        guard count <= 12_000, stack.count < 40 else { parser.abortParsing(); return }
        let node = DLNAXMLNode(name.components(separatedBy: ":").last ?? name)
        if let parent = stack.last { parent.children.append(node) } else { root = node }
        stack.append(node)
    }
    func parser(_ parser: XMLParser, foundCharacters text: String) { stack.last?.text += text }
    func parser(_ parser: XMLParser, foundCDATA block: Data) { stack.last?.text += String(data: block, encoding: .utf8) ?? "" }
    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) { _ = stack.popLast() }
}

public enum DLNAProtocol {
    public static func xml(_ data: Data) throws -> DLNAXMLNode {
        guard data.count <= 1024 * 1024 else { throw TVError.message("电视返回的数据过大。") }
        let reader = DLNAXMLReader(), parser = XMLParser(data: data)
        parser.shouldResolveExternalEntities = false; parser.externalEntityResolvingPolicy = .never; parser.delegate = reader
        guard parser.parse(), let root = reader.root else { throw TVError.message("无法识别电视的响应。") }
        return root
    }
    public static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
    }
    public static func device(_ data: Data, at location: URL) throws -> DLNADevice {
        let root = try xml(data)
        guard let node = root.descendants("device").first(where: { $0.value("deviceType").contains(":MediaRenderer:") }) else {
            throw TVError.message("这个设备不支持 DLNA 视频投屏。")
        }
        let declaredBase = URL(string: root.value("URLBase"))
        let base = declaredBase.flatMap { ["http", "https"].contains($0.scheme?.lowercased() ?? "") ? $0 : nil } ?? location
        func service(_ kind: String) -> DLNAService? {
            guard let service = node.child("serviceList")?.children.first(where: { $0.value("serviceType").contains(":\(kind):") }),
                  let control = URL(string: service.value("controlURL"), relativeTo: base)?.absoluteURL,
                  ["http", "https"].contains(control.scheme?.lowercased() ?? ""), control.host == location.host,
                  control.user == nil, control.password == nil else { return nil }
            let scpd = service.value("SCPDURL")
            let description = scpd.isEmpty ? nil : URL(string: scpd, relativeTo: base)?.absoluteURL
            return DLNAService(type: service.value("serviceType"), controlURL: control,
                               descriptionURL: description.flatMap { $0.host == location.host && ["http", "https"].contains($0.scheme ?? "") ? $0 : nil })
        }
        guard let transport = service("AVTransport") else { throw TVError.message("电视未提供视频播放控制接口。") }
        let id = node.value("UDN")
        return DLNADevice(id: id.isEmpty ? location.absoluteString : id,
                          name: node.value("friendlyName").isEmpty ? "DLNA 电视" : node.value("friendlyName"),
                          descriptionURL: location, transport: transport, rendering: service("RenderingControl"))
    }
    public static func actions(_ data: Data) throws -> Set<String> {
        Set(try xml(data).descendants("action").map { $0.value("name") }.filter { !$0.isEmpty })
    }
    public static func envelope(service: String, action: String, arguments: [(String, String)]) -> Data {
        let arguments = arguments.map { "<\($0.0)>\(escape($0.1))</\($0.0)>" }.joined()
        return Data("""
        <?xml version="1.0" encoding="utf-8"?>
        <s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/"><s:Body><u:\(action) xmlns:u="\(escape(service))">\(arguments)</u:\(action)></s:Body></s:Envelope>
        """.utf8)
    }
    public static func values(_ data: Data, action: String) throws -> [String: String] {
        let root = try xml(data)
        if let fault = root.descendants("UPnPError").first { throw DLNAFault(Int(fault.value("errorCode")) ?? 501) }
        guard let response = root.descendants(action + "Response").first else { throw TVError.message("电视没有返回有效的操作结果。") }
        return Dictionary(response.children.map { ($0.name, $0.text.trimmingCharacters(in: .whitespacesAndNewlines)) }, uniquingKeysWith: { _, new in new })
    }
    public static func seconds(_ text: String?) -> Double {
        guard let text, text != "NOT_IMPLEMENTED" else { return 0 }
        let values = text.split(separator: ":").compactMap { Double($0) }
        guard values.count == 3, values.allSatisfy({ $0.isFinite && $0 >= 0 }), values[1] < 60, values[2] < 60 else { return 0 }
        let seconds = values[0] * 3600 + values[1] * 60 + values[2]
        return seconds.isFinite && seconds <= Double(Int32.max) ? seconds : 0
    }
    public static func time(_ seconds: Double) -> String {
        let total = Int(min(Double(Int32.max), max(0, seconds.isFinite ? seconds : 0)))
        return String(format: "%02d:%02d:%02d", total / 3600, total / 60 % 60, total % 60)
    }
    public static func metadata(title: String, mediaURL: URL, mime: String) -> String {
        """
        <DIDL-Lite xmlns="urn:schemas-upnp-org:metadata-1-0/DIDL-Lite/" xmlns:dc="http://purl.org/dc/elements/1.1/" xmlns:upnp="urn:schemas-upnp-org:metadata-1-0/upnp/"><item id="0" parentID="-1" restricted="1"><dc:title>\(escape(title))</dc:title><upnp:class>object.item.videoItem</upnp:class><res protocolInfo="http-get:*:\(escape(mime)):*">\(escape(mediaURL.absoluteString))</res></item></DIDL-Lite>
        """
    }
}

public struct DLNAClient: Sendable {
    private let session: URLSession
    private let airPlayVideo = AirPlayVideoClient()
    public init(session: URLSession? = nil) {
        if let session { self.session = session }
        else {
            let config = URLSessionConfiguration.ephemeral
            config.timeoutIntervalForRequest = 5; config.timeoutIntervalForResource = 8
            config.connectionProxyDictionary = [:]
            self.session = URLSession(configuration: config)
        }
    }
    private func request(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse else { throw TVError.message("电视连接没有返回有效响应。") }
        var data = Data()
        for try await byte in bytes {
            guard data.count < 1024 * 1024 else { throw TVError.message("电视返回的数据过大。") }; data.append(byte)
        }
        return (data, http)
    }
    public func device(at url: URL) async throws -> DLNADevice {
        let (data, http) = try await request(URLRequest(url: url))
        guard (200..<300).contains(http.statusCode) else { throw TVError.message("无法读取电视设备信息。") }
        var result = try DLNAProtocol.device(data, at: url)
        for rendering in [false, true] {
            guard var service = rendering ? result.rendering : result.transport, let description = service.descriptionURL else { continue }
            if let (body, response) = try? await request(URLRequest(url: description)), (200..<300).contains(response.statusCode) {
                service.actions = (try? DLNAProtocol.actions(body)) ?? []
            }
            if rendering { result.rendering = service } else { result.transport = service }
        }
        return result
    }
    @discardableResult public func action(_ name: String, service: DLNAService, arguments: [(String, String)] = []) async throws -> [String: String] {
        if service.type == AirPlayVideoProtocol.serviceType {
            return try await airPlayVideo.action(name, endpoint: service.controlURL, arguments: arguments)
        }
        var request = URLRequest(url: service.controlURL, timeoutInterval: 5)
        request.httpMethod = "POST"; request.setValue("text/xml; charset=\"utf-8\"", forHTTPHeaderField: "Content-Type")
        request.setValue("\"\(service.type)#\(name)\"", forHTTPHeaderField: "SOAPAction")
        request.httpBody = DLNAProtocol.envelope(service: service.type, action: name, arguments: [("InstanceID", "0")] + arguments)
        let (data, http) = try await self.request(request)
        let values = try DLNAProtocol.values(data, action: name)
        guard (200..<300).contains(http.statusCode) else { throw TVError.message("电视未能完成操作。（HTTP \(http.statusCode)）") }
        return values
    }
    public func playAirPlayVideo(_ media: URL, on device: DLNADevice) async throws {
        guard device.isAirPlayVideo else { throw TVError.message("此设备没有提供 AirPlay 兼容接口。") }
        try await airPlayVideo.play(media, on: device.transport.controlURL)
    }
}
