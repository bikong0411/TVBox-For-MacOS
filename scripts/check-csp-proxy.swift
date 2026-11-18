import Foundation
import CryptoKit
import TVBoxCore

@main struct CheckCSPProxy {
    static func main() async throws {
        guard CommandLine.arguments.count==3 else{exit(2)}
        let assets=URL(fileURLWithPath:CommandLine.arguments[1]),fixture=URL(fileURLWithPath:CommandLine.arguments[2])
        let runtime=CSPBundledRuntime(assets:assets,storage:FileManager.default.temporaryDirectory.appendingPathComponent("csp-proxy-check-"+UUID().uuidString))
        defer{runtime.stop()}
        let component=try CSPComponent(fixture.absoluteString)
        let site=Site(key:"proxy-fixture",name:"标准代理测试",type:3,api:"csp_CSPFixture",csp:try CSPDefinition(component:component,api:"csp_CSPFixture",extend:"https://fixture.invalid/test.mp4"))
        let service=TVService(csp:CSPRPCTransport(runtime:runtime))
        let line=PlayLine(name:"测试线路",episodes:[Episode(name:"代理清单",url:"opaque:playlist")])
        let first=try await service.resolvePlayback(site:site,line:line,episode:line.episodes[0])
        guard first.lease != nil else{throw TVError.message("Proxy lease absent")}
        let configuration=URLSessionConfiguration.ephemeral;configuration.connectionProxyDictionary=[:]
        let session=URLSession(configuration:configuration);defer{session.invalidateAndCancel()}
        let (bytes,response)=try await session.data(from:first.url)
        let playlist=String(decoding:bytes,as:UTF8.self)
        guard (response as? HTTPURLResponse)?.statusCode==200,playlist.hasPrefix("#EXTM3U"),!playlist.contains(":-1"),!playlist.contains("/media/") else{throw TVError.message("HLS proxy addresses were not privately mapped")}
        let expression=try NSRegularExpression(pattern:#"URI="([^"]+)""#)
        let match=expression.firstMatch(in:playlist,range:NSRange(playlist.startIndex...,in:playlist))!
        let key=URL(string:String(playlist[Range(match.range(at:1),in:playlist)!]))!
        let segment=URL(string:playlist.components(separatedBy:.newlines).first{!$0.isEmpty && !$0.hasPrefix("#")}!)!
        let (keyBytes,_)=try await session.data(from:key)
        var range=URLRequest(url:segment);range.setValue("bytes=2-5",forHTTPHeaderField:"Range")
        let (segmentBytes,segmentResponse)=try await session.data(for:range)
        guard keyBytes==Data(repeating:0,count:16),segmentBytes==Data("2345".utf8),(segmentResponse as? HTTPURLResponse)?.statusCode==206 else{throw TVError.message("Proxy key or byte ranges changed")}
        var head=URLRequest(url:segment);head.httpMethod="HEAD"
        let (empty,headResponse)=try await session.data(for:head)
        guard empty.isEmpty,(headResponse as? HTTPURLResponse)?.statusCode==200 else{throw TVError.message("Proxy HEAD failed")}
        let connection=try await runtime.connection(componentHash:SHA256.hash(data:Data(contentsOf:fixture)).map{String(format:"%02x",$0)}.joined())
        let (_,denied)=try await session.data(from:connection.endpoint.appendingPathComponent("media/"+String(repeating:"a",count:64)+"/proxy?mode=key"))
        guard (denied as? HTTPURLResponse)?.statusCode==401 else{throw TVError.message("Unauthenticated proxy was accepted")}
        first.lease?.stop()
        try await Task.sleep(nanoseconds:300_000_000)
        do{_ = try await session.data(from:first.url);throw TVError.message("Stopped endpoint remained accessible")}
        catch is URLError{ }
        do{_ = try await service.resolvePlayback(site:site,line:line,episode:Episode(name:"空结果",url:"opaque:empty"));throw TVError.message("Empty player result was accepted")}
        catch{guard error.localizedDescription.contains("没有返回") else{throw error}}
        print("PASS actual Android proxy: HLS and AES key remapping, Range, HEAD, authentication, lease cleanup, empty playback result")
    }
}
