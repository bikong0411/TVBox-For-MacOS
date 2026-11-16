import Foundation
import Testing
@testable import TVBoxCore

@Suite struct PlaybackConnectionMemoryTests {
    let first = URL(string: "https://media.invalid/episode-1.m3u8?token=one")!
    let next = URL(string: "https://media.invalid/episode-2.m3u8?token=two")!
    let now = Date(timeIntervalSince1970: 10000)

    @Test func scopesByOriginAndCredentialsButAllowsOtherEpisodes() {
        var memory = PlaybackConnectionMemory()
        let result1 = !memory.prefersCompatibility(for: first, headers: [:], now: now)
        #expect(result1)
        memory.rememberCompatibility(for: first, headers: ["Authorization": "Bearer fixture", "Referer": "https://site.invalid/"], now: now)
        let result2 = memory.prefersCompatibility(for: next, headers: ["referer": "https://site.invalid/", "authorization": "Bearer fixture"], now: now)
        #expect(result2)
        let result3 = !memory.prefersCompatibility(for: next, headers: ["Authorization": "Bearer other", "Referer": "https://site.invalid/"], now: now)
        #expect(result3)
        let result4 = !memory.prefersCompatibility(for: next, headers: [:], now: now)
        #expect(result4)
        for url in ["http://media.invalid/a", "https://media.invalid:444/a", "https://other.invalid/a", "https://user:password@media.invalid/a"] {
            let result5 = !memory.prefersCompatibility(for: URL(string: url)!, headers: ["Authorization": "Bearer fixture", "Referer": "https://site.invalid/"], now: now)
            #expect(result5)
        }
    }
    @Test func normalizesDefaultPortsAndHostCase() {
        var memory = PlaybackConnectionMemory()
        memory.rememberCompatibility(for: first, headers: [:], now: now)
        let result6 = memory.prefersCompatibility(for: URL(string: "https://MEDIA.invalid:443/b")!, headers: [:], now: now)
        #expect(result6)
    }
    @Test func expiresFromSuccessRatherThanLastLookup() {
        var memory = PlaybackConnectionMemory(lifetime: 10)
        memory.rememberCompatibility(for: first, headers: [:], now: now)
        let result7 = memory.prefersCompatibility(for: next, headers: [:], now: now.addingTimeInterval(9))
        #expect(result7)
        let result8 = !memory.prefersCompatibility(for: next, headers: [:], now: now.addingTimeInterval(10))
        #expect(result8)
        memory.rememberCompatibility(for: first, headers: [:], now: now)
        let result9 = !memory.prefersCompatibility(for: next, headers: [:], now: now.addingTimeInterval(-1))
        #expect(result9)
    }
    @Test func forgettingFailedHintPreservesOtherOrigins() {
        var memory = PlaybackConnectionMemory()
        let other = URL(string: "https://other.invalid/a")!
        memory.rememberCompatibility(for: first, headers: [:], now: now)
        memory.rememberCompatibility(for: other, headers: [:], now: now)
        memory.forget(next, headers: [:])
        let result10 = !memory.prefersCompatibility(for: first, headers: [:], now: now)
        #expect(result10)
        let result11 = memory.prefersCompatibility(for: other, headers: [:], now: now)
        #expect(result11)
    }
    @Test func evictsLeastRecentlyUsedAndRejectsNonHTTP() {
        var memory = PlaybackConnectionMemory(capacity: 2)
        let second = URL(string: "https://second.invalid/a")!, third = URL(string: "https://third.invalid/a")!
        memory.rememberCompatibility(for: first, headers: [:], now: now)
        memory.rememberCompatibility(for: second, headers: [:], now: now.addingTimeInterval(1))
        let result12 = memory.prefersCompatibility(for: first, headers: [:], now: now.addingTimeInterval(2))
        #expect(result12)
        memory.rememberCompatibility(for: third, headers: [:], now: now.addingTimeInterval(3))
        let result13 = !memory.prefersCompatibility(for: second, headers: [:], now: now.addingTimeInterval(3))
        #expect(result13)
        let result14 = memory.prefersCompatibility(for: first, headers: [:], now: now.addingTimeInterval(3))
        #expect(result14)
        for url in [URL(fileURLWithPath: "/tmp/a.mp4"), URL(string: "rtsp://media.invalid/live")!] {
            memory.rememberCompatibility(for: url, headers: [:], now: now)
            let result15 = !memory.prefersCompatibility(for: url, headers: [:], now: now)
            #expect(result15)
        }
    }
}
