import Foundation
import CryptoKit
import Testing
@testable import TVBoxCore

private struct RefreshRuntime: CSPRuntimeProvider {
    let token: String
    func connection(componentHash: String) async throws -> CSPWorkerConnection {
        try CSPWorkerConnection(endpoint: URL(string: "http://127.0.0.1:18794")!, token: token)
    }
}

@Suite struct CSPSubscriptionRefreshTests {
    private let jar = Data([0x50,0x4b,0x03,0x04,1,2,3,4])
    private func md5(_ bytes: Data) -> String { Insecure.MD5.hash(data: bytes).map { String(format: "%02x", $0) }.joined() }
    private func config(_ origin: URL, digest: String?, api: String = "csp_Fixture", algorithm: String = "md5") throws -> Data {
        let component = origin.deletingLastPathComponent().appendingPathComponent("fan.jar").absoluteString + (digest.map { ";\(algorithm);\($0)" } ?? "")
        return try JSONSerialization.data(withJSONObject: ["spider":component, "sites":[["key":"fixture", "name":"Fixture", "type":3, "api":api]]])
    }
    @Test func newerSubscriptionRecoversOnceAndStagesMetadataAfterVerifiedLoad() async throws {
        let token = SHA256.hash(data: Data(UUID().uuidString.utf8)).map { String(format:"%02x",$0) }.joined()
        let origin = URL(string: "https://\(token).fixture.invalid/config.json")!
        let fresh = try config(origin, digest: md5(jar))
        RefreshProtocol.register(token, config: fresh, jar: jar)
        defer { RefreshProtocol.remove(token) }
        let session = session(); defer { session.invalidateAndCancel() }
        let transport = CSPRPCTransport(runtime: RefreshRuntime(token: token), session: session, localOverride: session)
        let service = TVService(session: session, csp: transport)
        var library = SourceLibrary()
        _ = try library.add(Parser.configuration(config(origin, digest: md5(Data("old JAR".utf8))), base: origin))
        let original = try #require(library.activeVOD)
        let result = try await service.catalogRefreshingCSP(source: original, siteID: "fixture", category: nil, search: "", page: 1)
        let updated = try #require(result.refreshed)
        #expect(result.catalog.videos.first?.id == "v1" && result.categories?.first?.id == "c1")
        #expect(updated.configuration.sites.first?.csp?.component.digest == md5(jar))
        #expect(updated.id == original.id && updated.name == original.name && updated.selectedSiteID == original.selectedSiteID)
        #expect(updated.runtimeSite("fixture")?.key == original.runtimeSite("fixture")?.key)
        #expect(library.activeVOD == original)
        let counts = RefreshProtocol.state(token)
        #expect(counts.configRequests == 1 && (2...4).contains(counts.jarRequests) && counts.loads == 1)
        #expect(counts.allConfigRequestsFresh && counts.allJarRequestsFresh)
    }
    @Test func staleSubscriptionStopsAfterOneRefreshAndNeverLoadsUnverifiedBytes() async throws {
        let token = SHA256.hash(data: Data(UUID().uuidString.utf8)).map { String(format:"%02x",$0) }.joined()
        let origin = URL(string: "https://\(token).fixture.invalid/config.json")!
        let old = try config(origin, digest: md5(Data("old JAR".utf8)))
        RefreshProtocol.register(token, config: old, jar: jar)
        defer { RefreshProtocol.remove(token) }
        let session = session(); defer { session.invalidateAndCancel() }
        let transport = CSPRPCTransport(runtime: RefreshRuntime(token: token), session: session, localOverride: session)
        let service = TVService(session: session, csp: transport)
        var library = SourceLibrary(); _ = try library.add(Parser.configuration(old, base: origin))
        let source = try #require(library.activeVOD)
        await #expect(throws: CSPFailure.refreshedChecksumMismatch) {
            try await service.catalogRefreshingCSP(source: source, siteID: "fixture", category: nil, search: "", page: 1)
        }
        let counts = RefreshProtocol.state(token)
        #expect(counts.configRequests == 1 && (2...4).contains(counts.jarRequests) && counts.loads == 0)
        #expect(library.activeVOD == source)
    }
    @Test func localPinIsPreservedAndEntryErrorsDoNotRefreshSubscriptions() async throws {
        for pinned in [true, false] {
            let token = SHA256.hash(data: Data(UUID().uuidString.utf8)).map { String(format:"%02x",$0) }.joined()
            let origin = URL(string: "https://\(token).fixture.invalid/config.json")!
            let bytes = try config(origin, digest: md5(jar))
            RefreshProtocol.register(token, config: bytes, jar: jar, loadError: pinned ? nil : "ENTRY_CLASS_MISSING")
            defer { RefreshProtocol.remove(token) }
            let session = session(); defer { session.invalidateAndCancel() }
            var library = SourceLibrary(); _ = try library.add(Parser.configuration(bytes, base: origin))
            if pinned {
                try library.setCSPComponent(CSPComponent(origin.deletingLastPathComponent().appendingPathComponent("fan.jar").absoluteString + ";md5;" + md5(Data("pinned bytes".utf8))), sourceID: library.activeVOD!.id, siteID: "fixture")
            }
            let source = try #require(library.activeVOD)
            let transport = CSPRPCTransport(runtime: RefreshRuntime(token: token), session: session, localOverride: session)
            let service = TVService(session: session, csp: transport)
            await #expect(throws: pinned ? CSPFailure.localComponentMismatch : CSPFailure.entryClassMissing) {
                try await service.catalogRefreshingCSP(source: source, siteID: "fixture", category: nil, search: "", page: 1)
            }
            #expect(RefreshProtocol.state(token).configRequests == 0)
            #expect(library.activeVOD == source)
        }
    }
    @Test func refreshRequiresSameOriginSameInterfaceAndAnIntegrityDeclaration() throws {
        let origin = URL(string:"https://fixture.invalid/config.json")!
        var library = SourceLibrary(); _ = try library.add(Parser.configuration(config(origin,digest:md5(jar)),base:origin))
        let source = try #require(library.activeVOD)
        for value in [try config(origin,digest:md5(jar),api:"csp_Other"), try config(origin,digest:nil)] {
            #expect(throws: CSPFailure.interfaceChanged) { try source.refreshingCSP(Parser.configuration(value,base:origin),siteID:"fixture") }
        }
        let other = URL(string:"https://other.invalid/config.json")!
        #expect(throws: CSPFailure.interfaceChanged) { try source.refreshingCSP(Parser.configuration(config(other,digest:md5(jar)),base:other),siteID:"fixture") }
        _ = try library.add(Parser.configuration(config(origin,digest:String(repeating:"a",count:64),algorithm:"sha256"),base:origin))
        let strong = try #require(library.activeVOD)
        #expect(throws: CSPFailure.interfaceChanged) { try strong.refreshingCSP(source.configuration,siteID:"fixture") }
        #expect(source.configuration.sites.first?.api == "csp_Fixture")
    }
    private func session() -> URLSession {
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [RefreshProtocol.self]
        return URLSession(configuration: config)
    }
}

private final class RefreshProtocol: URLProtocol {
    struct State {
        let configuration: Data; let jar: Data; let loadError: String?
        var configRequests = 0; var jarRequests = 0; var loads = 0
        var allConfigRequestsFresh = true; var allJarRequestsFresh = true
    }
    private static let lock = NSLock()
    private static var states: [String: State] = [:]
    static func register(_ token:String,config:Data,jar:Data,loadError:String?=nil) { lock.lock();defer{lock.unlock()};states[token]=State(configuration:config,jar:jar,loadError:loadError) }
    static func state(_ token:String)->State { lock.lock();defer{lock.unlock()};return states[token]! }
    static func remove(_ token:String) { lock.lock();defer{lock.unlock()};states.removeValue(forKey:token) }
    override class func canInit(with request:URLRequest)->Bool { true }
    override class func canonicalRequest(for request:URLRequest)->URLRequest { request }
    override func startLoading() {
        do {
            let token = request.url!.host == "127.0.0.1" ? request.value(forHTTPHeaderField:"Authorization")!.replacingOccurrences(of:"Bearer ",with:"") : String(request.url!.host!.split(separator:".")[0])
            var command = ""
            if request.url!.path == "/rpc" { command = (try JSONSerialization.jsonObject(with:body()) as! [String:Any])["command"] as! String }
            Self.lock.lock()
            guard var state = Self.states[token] else { Self.lock.unlock(); throw URLError(.cancelled) }
            let data: Data
            let fresh = request.cachePolicy == .reloadIgnoringLocalCacheData && request.value(forHTTPHeaderField:"Cache-Control") == "no-cache"
            if request.url!.path == "/config.json" { state.configRequests += 1; state.allConfigRequestsFresh = state.allConfigRequestsFresh && fresh; data = state.configuration }
            else if request.url!.path == "/fan.jar" { state.jarRequests += 1; state.allJarRequestsFresh = state.allJarRequestsFresh && fresh; data = state.jar }
            else {
                let object:[String:Any]
                if command == "load" { state.loads += 1; object = state.loadError.map { ["error":$0] } ?? ["loaded":true] }
                else { object = ["result":["class":[["type_id":"c1","type_name":"Category"]],"list":[["vod_id":"v1","vod_name":"Title"]]]] }
                data = try JSONSerialization.data(withJSONObject:object)
            }
            Self.states[token] = state; Self.lock.unlock()
            client?.urlProtocol(self,didReceive:HTTPURLResponse(url:request.url!,statusCode:200,httpVersion:nil,headerFields:nil)!,cacheStoragePolicy:.notAllowed)
            client?.urlProtocol(self,didLoad:data);client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self,didFailWithError:error) }
    }
    private func body() -> Data {
        if let data=request.httpBody { return data }
        guard let stream=request.httpBodyStream else { return Data() }
        stream.open();defer{stream.close()};var result=Data(),bytes=[UInt8](repeating:0,count:4096)
        while stream.hasBytesAvailable { let n=stream.read(&bytes,maxLength:bytes.count);if n<=0 {break};result.append(contentsOf:bytes.prefix(n)) }
        return result
    }
    override func stopLoading() {}
}
