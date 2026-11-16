import Foundation
import Testing
@testable import TVBoxCore

@Suite struct DLNATests {
    private let location = URL(string: "http://192.168.1.8:1234/device.xml")!
    @Test func parsesDeviceAndRejectsForeignControls() throws {
        let xml = """
        <root><URLBase>http://192.168.1.8:4321/</URLBase><device><deviceType>urn:schemas-upnp-org:device:MediaRenderer:1</deviceType><friendlyName>客厅 &amp; 电视</friendlyName><UDN>uuid:tv</UDN><serviceList><service><serviceType>urn:schemas-upnp-org:service:AVTransport:1</serviceType><controlURL>/play</controlURL><SCPDURL>/actions.xml</SCPDURL></service></serviceList></device></root>
        """
        let device = try DLNAProtocol.device(Data(xml.utf8), at: location)
        #expect(device.name == "客厅 & 电视")
        #expect(device.transport.controlURL.absoluteString == "http://192.168.1.8:4321/play")
        #expect(device.transport.descriptionURL?.path == "/actions.xml")
        #expect(throws: (any Error).self) { try DLNAProtocol.device(Data(xml.replacingOccurrences(of: "<controlURL>/play", with: "<controlURL>http://example.com/play").utf8), at: location) }
    }
    @Test func parsesNamespacedSOAPAndFault() throws {
        let response = Data("<s:Envelope xmlns:s='urn:soap'><s:Body><u:GetTransportInfoResponse xmlns:u='urn:av'><CurrentTransportState>PLAYING</CurrentTransportState></u:GetTransportInfoResponse></s:Body></s:Envelope>".utf8)
        #expect(try DLNAProtocol.values(response, action: "GetTransportInfo")["CurrentTransportState"] == "PLAYING")
        do {
            _ = try DLNAProtocol.values(Data("<Envelope><UPnPError><errorCode>711</errorCode></UPnPError></Envelope>".utf8), action: "Seek")
            Issue.record("SOAP fault was ignored")
        } catch let fault as DLNAFault { #expect(fault.code == 711); #expect(fault.localizedDescription.contains("跳转")) }
        #expect(throws: (any Error).self) { try DLNAProtocol.xml(Data(repeating: 65, count: 1024 * 1024 + 1)) }
        #expect(throws: (any Error).self) { try DLNAProtocol.xml(Data((String(repeating: "<a>", count: 50) + String(repeating: "</a>", count: 50)).utf8)) }
    }
    @Test func escapingMetadataAndTimes() throws {
        let metadata = DLNAProtocol.metadata(title: "电影 <A> & B", mediaURL: URL(string: "http://127.0.0.1/a?x=1&y=2")!, mime: "video/mp4")
        let envelope = DLNAProtocol.envelope(service: "urn:av", action: "SetAVTransportURI", arguments: [("CurrentURIMetaData", metadata)])
        let node = try DLNAProtocol.xml(envelope)
        let nested = try DLNAProtocol.xml(Data(node.descendants("CurrentURIMetaData")[0].text.utf8))
        #expect(nested.descendants("title")[0].text == "电影 <A> & B")
        #expect(DLNAProtocol.seconds("01:02:03.5") == 3723.5)
        for invalid in ["NOT_IMPLEMENTED", "00:80:00", "nan:00:01", "bad", "-1:00:00"] { #expect(DLNAProtocol.seconds(invalid) == 0) }
        #expect(DLNAProtocol.time(3723.9) == "01:02:03")
    }
    @Test func validatesSSDPLocation() {
        let valid = "HTTP/1.1 200 OK\r\nLOCATION: http://192.168.1.8:1234/device.xml\r\n\r\n"
        #expect(SSDPResponse.parse(Data(valid.utf8), sender: "192.168.1.8")?.location == location)
        #expect(SSDPResponse.parse(Data(valid.utf8), sender: "192.168.1.9") == nil)
        #expect(SSDPResponse.parse(Data(valid.replacingOccurrences(of: "192.168.1.8", with: "8.8.8.8").utf8), sender: "8.8.8.8") == nil)
    }
    @Test func rangesBoundaries() {
        #expect(CastMediaRelay.byteRange("bytes=2-4", size: 10) == 2..<5)
        #expect(CastMediaRelay.byteRange("bytes=-2", size: 10) == 8..<10)
        #expect(CastMediaRelay.byteRange("bytes=8-", size: 10) == 8..<10)
        for invalid in ["bytes=10-", "bytes=4-2", "bytes=0-1,3-4", "bytes=-0"] { #expect(CastMediaRelay.byteRange(invalid, size: 10) == nil) }
    }
    @Test func relayStreamsFilesRangesAndRewritesLocalHLS() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let media = directory.appendingPathComponent("part.ts")
        try Data("0123456789".utf8).write(to: media)
        let config = URLSessionConfiguration.ephemeral; config.connectionProxyDictionary = [:]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        let relay = CastMediaRelay(source: media, headers: [:], peer: "127.0.0.1")
        let url = try await relay.start(); defer { relay.stop() }
        var request = URLRequest(url: url); request.setValue("bytes=2-4", forHTTPHeaderField: "Range")
        let (body, response) = try await session.data(for: request)
        #expect((response as? HTTPURLResponse)?.statusCode == 206); #expect(String(data: body, encoding: .utf8) == "234")
        request.httpMethod = "HEAD"
        let (head, headResponse) = try await session.data(for: request)
        #expect(head.isEmpty); #expect((headResponse as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Length") == "3")
        let (_, missing) = try await session.data(from: url.deletingLastPathComponent().appendingPathComponent("wrong.ts"))
        #expect((missing as? HTTPURLResponse)?.statusCode == 404)
        let playlist = directory.appendingPathComponent("index.m3u8")
        try Data("#EXTM3U\n#EXT-X-KEY:METHOD=AES-128,URI=\"key.bin\"\n#EXTINF:1,\npart.ts\n".utf8).write(to: playlist)
        let hls = CastMediaRelay(source: playlist, headers: [:], peer: "127.0.0.1")
        let hlsURL = try await hls.start(); defer { hls.stop() }
        let (manifest, _) = try await session.data(from: hlsURL)
        let text = String(decoding: manifest, as: UTF8.self)
        #expect(!text.contains("file:")); #expect(text.contains("URI=\"http://127.0.0.1:"))
        let segment = try #require(text.components(separatedBy: .newlines).first { $0.hasPrefix("http://") }.flatMap(URL.init(string:)))
        let (bytes, _) = try await session.data(from: segment)
        #expect(String(data: bytes, encoding: .utf8) == "0123456789")
    }
}
