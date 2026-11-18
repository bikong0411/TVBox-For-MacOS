import Foundation
import Testing
@testable import TVBoxCore

@Suite struct RepositoryCatalogTests {
    @Test func storeHouseAndURLsNormalizeIntoUniqueValidReferences() throws {
        let bytes=Data(#"{"storeHouse":[{"sourceName":"仓库 A","sourceUrl":"../a/config.json"},{"sourceName":"重复","sourceUrl":"../a/config.json"},{"sourceName":"无效","sourceUrl":"javascript:alert(1)"},{"sourceName":"空","sourceUrl":" "}],"urls":[{"name":"仓库 B","url":"https://b.invalid/dir/config.json"}]}"#.utf8)
        let catalog=try Parser.configuration(bytes,base:URL(string:"https://a.invalid/catalog/index.json"))
        #expect(catalog.sites.isEmpty && catalog.subscriptions.count==2)
        #expect(catalog.subscriptions.map(\.url)==["https://b.invalid/dir/config.json","https://a.invalid/a/config.json"])
        #expect(catalog.subscriptions.map(\.name)==["仓库 B","仓库 A"])
        #expect(throws:(any Error).self) {try Parser.configuration(Data(#"{"storeHouse":[{"sourceUrl":""}]}"#.utf8))}
    }
    @Test func repositoryChildrenKeepTheirOwnSpiderBaseAndIdentity() async throws {
        let config=URLSessionConfiguration.ephemeral;config.protocolClasses=[RepositoryProtocol.self]
        let session=URLSession(configuration:config);defer{session.invalidateAndCancel()}
        let service=TVService(session:session)
        let root=try await service.configuration(at:URL(string:"https://root.invalid/catalog.json")!)
        #expect(root.subscriptions.count==2 && root.sites.isEmpty)
        var library=SourceLibrary();_ = try library.add(root)
        for child in root.subscriptions {
            let loaded=try await service.configuration(at:URL(string:child.url)!)
            _ = try library.add(loaded,name:child.name)
        }
        #expect(library.vodSources.count==3)
        let a=library.vodSources[1],b=library.vodSources[2]
        #expect(a.runtimeSite("shared")?.key != b.runtimeSite("shared")?.key)
        #expect(a.runtimeSite("shared")?.csp?.component.url.absoluteString=="https://a.invalid/repo/jar/one.jar")
        #expect(b.runtimeSite("shared")?.csp?.component.url.absoluteString=="https://b.invalid/other/components/two.jar")
        #expect(a.runtimeSite("shared")?.csp?.configurationURL?.absoluteString==root.subscriptions[0].url)
        #expect(b.runtimeSite("shared")?.csp?.extend=="second")
        let restored=try JSONDecoder().decode(SourceLibrary.self,from:JSONEncoder().encode(library))
        #expect(restored.vodSources==library.vodSources)
    }
    @Test func catalogChildCanBeAnotherCatalogOrALivePlaylist() throws {
        let root=try Parser.configuration(Data(#"{"storeHouse":[{"sourceName":"下级","sourceUrl":"next.json"}]}"#.utf8),base:URL(string:"https://fixture.invalid/repos/root.json"))
        var library=SourceLibrary();_ = try library.add(root)
        let selected=library.selectedVODID
        let live=try Parser.configuration(Data("#EXTM3U\n#EXTINF:-1,公开测试频道\nhttps://fixture.invalid/live.m3u8\n".utf8),base:URL(string:"https://fixture.invalid/live.m3u"))
        _ = try library.add(live)
        #expect(library.selectedVODID==selected && library.liveSources.count==1)
        #expect(library.activeVOD?.configuration.subscriptions[0].url=="https://fixture.invalid/repos/next.json")
    }
}

private final class RepositoryProtocol: URLProtocol {
    override class func canInit(with request:URLRequest)->Bool {true}
    override class func canonicalRequest(for request:URLRequest)->URLRequest {request}
    override func startLoading() {
        let url=request.url!,body:String
        if url.host=="root.invalid" {body = #"{"storeHouse":[{"sourceName":"A","sourceUrl":"https://a.invalid/repo/config.json"},{"sourceName":"B","sourceUrl":"https://b.invalid/other/config.json"}]}"#}
        else if url.host=="a.invalid" {body = #"{"spider":"./jar/one.jar","sites":[{"key":"shared","name":"A","type":3,"api":"csp_Fixture","ext":"first"}]}"#}
        else {body = #"{"spider":"wrong-global.jar","sites":[{"key":"shared","name":"B","type":3,"api":"csp_Fixture","jar":"./components/two.jar","ext":"second"}]}"#}
        client?.urlProtocol(self,didReceive:HTTPURLResponse(url:url,statusCode:200,httpVersion:nil,headerFields:nil)!,cacheStoragePolicy:.notAllowed)
        client?.urlProtocol(self,didLoad:Data(body.utf8));client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
