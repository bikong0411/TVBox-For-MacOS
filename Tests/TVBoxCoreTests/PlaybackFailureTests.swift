import Foundation
import Testing
@testable import TVBoxCore

@Suite struct PlaybackFailureTests {
    @Test func nestedTLSErrorIsClassifiedWithoutExposingURL() {
        let inner = NSError(domain: NSURLErrorDomain, code: URLError.secureConnectionFailed.rawValue, userInfo: [NSURLErrorFailingURLStringErrorKey: "https://private.invalid/video?token=secret"])
        let outer = NSError(domain: "AVFoundationErrorDomain", code: -11800, userInfo: [NSUnderlyingErrorKey: inner])
        let result = PlaybackFailure(error: outer)
        #expect(result.kind == .tls)
        #expect(result.diagnostic.contains("-1200"))
        #expect(!result.diagnostic.contains("private.invalid"))
        #expect(!result.diagnostic.contains("secret"))
        #expect(result.title == "暂时连接不上片源")
        #expect(result.message.contains("安全连接"))
        #expect(result.message.contains("切换其他线路"))
        #expect(!result.message.contains("TLS"))
    }
    @Test func certificateReasonTakesPrecedenceOverGenericTLS() {
        let inner = NSError(domain: NSURLErrorDomain, code: URLError.serverCertificateHasBadDate.rawValue)
        let outer = NSError(domain: NSURLErrorDomain, code: URLError.secureConnectionFailed.rawValue, userInfo: [NSUnderlyingErrorKey: inner])
        #expect(PlaybackFailure(error: outer).kind == .certificate)
    }
    @Test func mediaHTTPFailuresAreDistinguished() {
        #expect(PlaybackFailure(error: nil, mediaStatusCodes: [403]).kind == .authentication)
        #expect(PlaybackFailure(error: nil, mediaStatusCodes: [404]).kind == .unavailable)
    }
    @Test func timeoutAndUnknownFailureRemainDifferent() {
        #expect(PlaybackFailure(error: URLError(.timedOut)).kind == .network)
        #expect(PlaybackFailure(error: nil).kind == .playback)
    }
    @Test func similarCodeOutsideURLDomainDoesNotImplyTLS() {
        let error = NSError(domain: "OtherDomain", code: URLError.secureConnectionFailed.rawValue)
        #expect(PlaybackFailure(error: error).kind == .playback)
    }
}
