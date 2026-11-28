import Foundation
import CryptoKit
import Testing
@testable import TVBoxCore

private struct RecoveryRuntime: CSPRuntimeProvider {
    let worker: CSPWorkerConnection
    var replacement: CSPWorkerConnection?
    func connection(componentHash: String) async throws -> CSPWorkerConnection { worker }
    func renewConnection(componentHash: String, replacing previous: CSPWorkerConnection) async throws -> CSPWorkerConnection {
        #expect(previous.token == worker.token)
        return replacement ?? worker
    }
}
@Suite struct CSPRPCRecoveryTests {
    @Test func searchCanContinueWhenTheWorkerHitsItsSessionLimit() async throws {
        let jar = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".jar")
        try Data([0x50, 0x4b, 1, 2]).write(to: jar)
        defer { try? FileManager.default.removeItem(at: jar) }
        let endpoint = try #require(URL(string: "http://127.0.0.1:18793"))
        let firstToken = SHA256.hash(data: Data(UUID().uuidString.utf8)).map { String(format: "%02x", $0) }.joined()
        let secondToken = SHA256.hash(data: Data(UUID().uuidString.utf8)).map { String(format: "%02x", $0) }.joined()
        RecoveryProtocol.register(firstToken, persistent: false, loadError: ["error": "SESSION_LIMIT"])
        RecoveryProtocol.register(secondToken, persistent: false)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RecoveryProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let runtime = RecoveryRuntime(worker: try CSPWorkerConnection(endpoint: endpoint, token: firstToken),
                                      replacement: try CSPWorkerConnection(endpoint: endpoint, token: secondToken))
        let transport = CSPRPCTransport(runtime: runtime, session: session, localOverride: session)
        let definition = try CSPDefinition(component: CSPComponent(jar.absoluteString), api: "csp_Fixture")
        let site = Site(key: "fixture", name: "Fixture", type: 3, api: "csp_Fixture", csp: definition)
        let data = try await transport.invoke(site: site, command: .search, arguments: ["query": "fixture"])
        #expect((try JSONSerialization.jsonObject(with: data) as? [String: Any])?["list"] != nil)
        let full = RecoveryProtocol.counts(firstToken)
        let renewed = RecoveryProtocol.counts(secondToken)
        #expect(full.loads == 1 && full.calls == 0)
        #expect(renewed.loads == 2 && renewed.calls == 2)
    }

    @Test func entryMismatchAndMissingLibrariesHaveDifferentMessagesWithoutRetry() async throws {
        for code in ["ENTRY_CLASS_MISSING", "CLASS_DEPENDENCY_MISSING", "SDK_ABI_MISMATCH"] {
            let jar=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".jar")
            try Data([0x50,0x4b,1,2]).write(to:jar);defer{try? FileManager.default.removeItem(at:jar)}
            let token=SHA256.hash(data:Data(UUID().uuidString.utf8)).map{String(format:"%02x",$0)}.joined()
            RecoveryProtocol.register(token,persistent:false,loadError:["error":code])
            let config=URLSessionConfiguration.ephemeral;config.protocolClasses=[RecoveryProtocol.self]
            let session=URLSession(configuration:config);defer{session.invalidateAndCancel()}
            let transport=CSPRPCTransport(runtime:RecoveryRuntime(worker:try CSPWorkerConnection(endpoint:URL(string:"http://127.0.0.1:18793")!,token:token)),session:session,localOverride:session)
            let site=Site(key:"fixture",name:"Fixture",type:3,api:"csp_Fixture",csp:try CSPDefinition(component:CSPComponent(jar.absoluteString),api:"csp_Fixture"))
            do {_ = try await transport.invoke(site:site,command:.home,arguments:[:]);Issue.record("Expected component error")}
            catch {
                #expect(error.localizedDescription.contains(code == "ENTRY_CLASS_MISSING" ? "入口不存在" : code == "SDK_ABI_MISMATCH" ? "版本不兼容" : "缺少所需的运行库"))
            }
            let counts=RecoveryProtocol.counts(token);#expect(counts.loads==1 && counts.calls==0)
        }
    }
    @Test func restartedWorkerReloadsOnceAndDoesNotLoopOnPersistentSessionLoss() async throws {
        for persistent in [false,true] {
            let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }
            let jar=root.appendingPathComponent("fixture.jar");try Data([0x50,0x4b,1,2]).write(to: jar)
            let token=SHA256.hash(data: Data(UUID().uuidString.utf8)).map { String(format:"%02x",$0) }.joined()
            RecoveryProtocol.register(token,persistent:persistent)
            let config=URLSessionConfiguration.ephemeral;config.protocolClasses=[RecoveryProtocol.self]
            let session=URLSession(configuration:config)
            defer { session.invalidateAndCancel() }
            let transport=CSPRPCTransport(runtime: RecoveryRuntime(worker:try CSPWorkerConnection(endpoint:URL(string:"http://127.0.0.1:18793")!,token:token)),session:session,localOverride:session)
            let site=Site(key:"fixture",name:"Recovery",type:3,api:"csp_Fixture",csp:try CSPDefinition(component:CSPComponent(jar.absoluteString),api:"csp_Fixture"))
            do {
                let data=try await transport.invoke(site:site,command:.home,arguments:[:])
                #expect(!persistent)
                #expect((try JSONSerialization.jsonObject(with:data) as? [String:Any])?["list"] != nil)
            } catch {
                #expect(persistent)
                #expect(error.localizedDescription.contains("重启"))
            }
            let counts=RecoveryProtocol.counts(token)
            #expect(counts.loads==2 && counts.calls==2)
        }
    }
}
private final class RecoveryProtocol: URLProtocol {
    private struct State {var loads=0;var calls=0;let persistent:Bool;var loadError:[String:Any]?}
    private static let lock=NSLock()
    private static var states:[String:State]=[:]
    static func register(_ token:String,persistent:Bool,loadError:[String:Any]?=nil) {lock.lock();defer{lock.unlock()};states[token]=State(persistent:persistent,loadError:loadError)}
    static func counts(_ token:String)->(loads:Int,calls:Int) {lock.lock();defer{lock.unlock()};let state=states.removeValue(forKey:token)!;return(state.loads,state.calls)}
    override class func canInit(with request:URLRequest)->Bool {true}
    override class func canonicalRequest(for request:URLRequest)->URLRequest {request}
    override func startLoading() {
        do {
            var body=request.httpBody ?? Data()
            if body.isEmpty,let stream=request.httpBodyStream {
                stream.open();defer{stream.close()};var bytes=[UInt8](repeating:0,count:4096)
                while stream.hasBytesAvailable {let count=stream.read(&bytes,maxLength:bytes.count);if count<=0{break};body.append(contentsOf:bytes.prefix(count))}
            }
            let command=(try JSONSerialization.jsonObject(with:body) as! [String:Any])["command"] as! String
            let token=request.value(forHTTPHeaderField:"Authorization")!.replacingOccurrences(of:"Bearer ",with:"")
            Self.lock.lock();var state=Self.states[token]!
            let response:[String:Any]
            if command=="load" {state.loads+=1;response=state.loadError ?? ["loaded":true]}
            else {state.calls+=1;response=state.persistent || state.calls==1 ? ["error":"SESSION_MISSING"] : ["result":["list":[]]]}
            Self.states[token]=state;Self.lock.unlock()
            client?.urlProtocol(self,didReceive:HTTPURLResponse(url:request.url!,statusCode:200,httpVersion:nil,headerFields:nil)!,cacheStoragePolicy:.notAllowed)
            client?.urlProtocol(self,didLoad:try JSONSerialization.data(withJSONObject:response));client?.urlProtocolDidFinishLoading(self)
        } catch {client?.urlProtocol(self,didFailWithError:error)}
    }
    override func stopLoading() {}
}
