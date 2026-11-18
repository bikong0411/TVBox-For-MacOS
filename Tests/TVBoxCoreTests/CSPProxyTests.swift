import Foundation
import Testing
@testable import TVBoxCore

@Suite struct CSPProxyTests {
    private let session = String(repeating: "a", count: 64)
    private var connection: CSPWorkerConnection { try! CSPWorkerConnection(endpoint: URL(string:"http://127.0.0.1:18793")!,token:String(repeating:"b",count:64)) }
    @Test func androidProxyUsesAuthenticatedWorkerRouteWithoutUnwrappingParameters() {
        let query="do=m3u8&url=https%3A%2F%2Ffixture.invalid%2Fx.m3u8%3Ftoken%3Da%2526b&headers=e30%3D"
        for authority in ["127.0.0.1:-1","localhost:9978","[::1]:9978","192.168.127.2:9978"] {
            let mapped=CSPRPCTransport.proxyTarget("http://"+authority+"/proxy?"+query,connection:connection,session:session)
            #expect(mapped?.absoluteString=="http://127.0.0.1:18793/media/"+session+"/proxy?"+query)
        }
    }
    @Test func arbitraryAddressesAndMalformedSessionsCannotReachTheRuntimeProxy() {
        for address in ["https://fixture.invalid/proxy?do=x","http://127.0.0.1:9978/private?do=x","http://user@127.0.0.1:9978/proxy?do=x","http://127.0.0.1:9978/proxy?do=x#fragment","http://127.0.0.1:9978/proxy?do=x\r\nInjected:x","http://127.0.0.1:9978/proxy?","http://127.0.0.1:9978/proxy?x="+String(repeating:"x",count:17000)] {
            #expect(CSPRPCTransport.proxyTarget(address,connection:connection,session:session)==nil)
        }
        #expect(CSPRPCTransport.proxyTarget("http://127.0.0.1:-1/proxy?do=x",connection:connection,session:"../other")==nil)
    }
    @Test func pluginCannotAuthorizeItsOwnLoopbackURL() throws {
        let bytes=Data(#"{"url":"http://127.0.0.1:18793/private","parse":0,"tvboxRuntimeProxy":true}"#.utf8)
        #expect(throws:(any Error).self) {try CSPPlayback(data:bytes)}
    }
}
