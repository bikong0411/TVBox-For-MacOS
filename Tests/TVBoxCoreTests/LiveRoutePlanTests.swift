import Foundation
import Testing
@testable import TVBoxCore

@Suite struct LiveRoutePlanTests {
    private func episodes(_ urls: [String]) -> [Episode] { urls.enumerated().map { Episode(name: "\($0.offset)", url: $0.element) } }
    @Test func startsWithChosenRouteAndMakesOnlyOnePass() {
        var plan = LiveRoutePlan(episodes: episodes(["a", "b", "c"]), startingAt: 1)
        let first = plan.next(), second = plan.next(), third = plan.next(), end = plan.next(), again = plan.next()
        #expect([first, second, third] == [1, 2, 0])
        #expect(end == nil && again == nil)
        #expect(plan.attemptedCount == 3)
    }
    @Test func duplicateAndEmptyURLsAreNotRetried() {
        var plan = LiveRoutePlan(episodes: episodes(["a", "", "a", "b", " "]), startingAt: 2)
        let first = plan.next(), second = plan.next(), end = plan.next()
        #expect([first, second] == [2, 3]); #expect(end == nil); #expect(plan.routeCount == 2)
    }
    @Test func emptyAndInvalidSelectionsDoNotCrash() {
        var empty = LiveRoutePlan(episodes: [], startingAt: 99)
        var invalid = LiveRoutePlan(episodes: episodes(["a", "b"]), startingAt: -1)
        let none = empty.next(), first = invalid.next()
        #expect(none == nil); #expect(first == 0)
    }
    @Test func newChannelHasIndependentAttempts() {
        var first = LiveRoutePlan(episodes: episodes(["a"]), startingAt: 0)
        _ = first.next()
        var second = LiveRoutePlan(episodes: episodes(["b", "c"]), startingAt: 0)
        let next = second.next()
        #expect(next == 0); #expect(second.attemptedCount == 1)
    }
    @Test func helperErrorsAreReadableAndDiagnosticsExcludeArbitraryContent() {
        let error = LiveRemuxFailure(log: "INPUT_OPEN (-1094995529): Invalid data https://private.invalid/?token=secret\nprivate payload")
        let failure = PlaybackFailure(error: error)
        #expect(error.kind == .invalidInput)
        #expect(failure.title == "直播线路数据无效")
        #expect(failure.message.contains("更换线路"))
        #expect(failure.diagnostic == "INPUT_OPEN (-1094995529)")
        #expect(!failure.diagnostic.contains("secret"))
        #expect(!failure.message.contains("secret"))
    }
    @Test func helperTimeoutAndCodecHaveDistinctMessages() {
        #expect(PlaybackFailure(error: LiveRemuxFailure(timeout: true)).kind == .network)
        let codec = LiveRemuxFailure(log: "VIDEO_CODEC_NOT_SUPPORTED (-38): Function not implemented")
        #expect(codec.kind == .unsupportedCodec)
        #expect(PlaybackFailure(error: codec).title == "此线路编码暂不支持")
    }
    @Test func missingMediaFileIsUnavailable() {
        let nested = NSError(domain: NSURLErrorDomain, code: URLError.fileDoesNotExist.rawValue, userInfo: [NSUnderlyingErrorKey: NSError(domain: "CoreMediaErrorDomain", code: -12938)])
        #expect(PlaybackFailure(error: nested).kind == .unavailable)
    }
}
