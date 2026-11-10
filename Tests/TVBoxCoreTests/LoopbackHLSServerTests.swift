import Foundation
import Testing
@testable import TVBoxCore

@Suite struct LoopbackHLSServerTests {
    private func fixture() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("0123456789".utf8).write(to: directory.appendingPathComponent("segment0.ts"))
        try Data("#EXTM3U\n".utf8).write(to: directory.appendingPathComponent("index.m3u8"))
        return directory
    }
    private func request(_ line: String, extra: String = "") -> Data { Data((line + "\r\nHost: localhost\r\n" + extra + "\r\n").utf8) }
    @Test func servesPlaylistAndByteRanges() throws {
        let directory = try fixture(); defer { try? FileManager.default.removeItem(at: directory) }
        let response = LoopbackHLSServer.response(for: request("GET /token/segment0.ts HTTP/1.1", extra: "Range: bytes=2-4\r\n"), directory: directory, token: "token")
        #expect(response.status == 206); #expect(String(data: response.body, encoding: .utf8) == "234")
        #expect(response.headers["Content-Range"] == "bytes 2-4/10")
        let playlist = LoopbackHLSServer.response(for: request("GET /token/index.m3u8 HTTP/1.1"), directory: directory, token: "token")
        #expect(playlist.headers["Content-Type"] == "application/vnd.apple.mpegurl")
    }
    @Test func rejectsTraversalAndWrongSession() throws {
        let directory = try fixture(); defer { try? FileManager.default.removeItem(at: directory) }
        for path in ["/other/index.m3u8", "/token/../index.m3u8", "/token/%2e%2e%2fsecret.ts", "/token/error.log", "/token/segment0.ts.tmp"] {
            #expect(LoopbackHLSServer.response(for: request("GET \(path) HTTP/1.1"), directory: directory, token: "token").status == 404)
        }
    }
    @Test func headHasCorrectLengthWithoutBody() throws {
        let directory = try fixture(); defer { try? FileManager.default.removeItem(at: directory) }
        let response = LoopbackHLSServer.response(for: request("HEAD /token/segment0.ts HTTP/1.1"), directory: directory, token: "token")
        #expect(response.status == 200); #expect(response.headers["Content-Length"] == "10"); #expect(response.body.isEmpty)
    }
    @Test func invalidRangesAndMethodsAreRejected() throws {
        let directory = try fixture(); defer { try? FileManager.default.removeItem(at: directory) }
        for value in ["bytes=99-", "bytes=4-2", "bytes=0-1,4-5", "bytes=-0"] {
            #expect(LoopbackHLSServer.response(for: request("GET /token/segment0.ts HTTP/1.1", extra: "Range: \(value)\r\n"), directory: directory, token: "token").status == 416)
        }
        #expect(LoopbackHLSServer.response(for: request("POST /token/index.m3u8 HTTP/1.1"), directory: directory, token: "token").status == 405)
    }
    @Test func supportsSuffixAndOpenEndedRanges() throws {
        let directory = try fixture(); defer { try? FileManager.default.removeItem(at: directory) }
        for value in ["bytes=-2", "bytes=8-"] {
            let response = LoopbackHLSServer.response(for: request("GET /token/segment0.ts HTTP/1.1", extra: "Range: \(value)\r\n"), directory: directory, token: "token")
            #expect(response.status == 206); #expect(String(data: response.body, encoding: .utf8) == "89")
        }
    }
}
