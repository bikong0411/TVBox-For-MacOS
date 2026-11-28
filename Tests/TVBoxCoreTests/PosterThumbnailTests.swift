import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import TVBoxCore

@Suite struct PosterThumbnailTests {
    @Test func concurrentSizesShareOneDownloadAndReturningToTheGridUsesTheCache() async throws {
        let (loader, url) = try fixture()
        let small = try #require(PosterThumbnailRequest(url: url, size: CGSize(width: 80, height: 120), scale: 2))
        let large = try #require(PosterThumbnailRequest(url: url, size: CGSize(width: 160, height: 240), scale: 2))
        let resized = try #require(PosterThumbnailRequest(url: url, size: CGSize(width: 83, height: 123), scale: 2))
        #expect(small == resized)

        async let first = loader.thumbnail(for: small)
        async let second = loader.thumbnail(for: large)
        let (grid, detail) = try await (first, second)
        #expect(grid.width == 192 && grid.height == 288)
        #expect((341...342).contains(detail.width) && detail.height == 512)
        #expect(try await loader.thumbnail(for: resized) === grid)
        #expect(PosterFixtureProtocol.counts(for: url).started == 1)
    }

    @Test func cancellingOneCardKeepsTheDownloadNeededByAnotherCard() async throws {
        let (loader, url) = try fixture()
        let request = try #require(PosterThumbnailRequest(url: url, size: CGSize(width: 80, height: 120), scale: 2))
        let second = Task { try await loader.thumbnail(for: request) }
        try await waitFor { PosterFixtureProtocol.counts(for: url).started > 0 }
        let first = Task { try await loader.thumbnail(for: request) }
        await Task.yield()
        first.cancel()
        await #expect(throws: CancellationError.self) { try await first.value }
        #expect(try await second.value.width == 192)
        #expect(PosterFixtureProtocol.counts(for: url).started == 1)
    }

    @Test func cancellingTheLastCardStopsTheDownloadAndAllowsALaterRetry() async throws {
        let (loader, url) = try fixture()
        let request = try #require(PosterThumbnailRequest(url: url, size: CGSize(width: 80, height: 120), scale: 2))
        let task = Task { try await loader.thumbnail(for: request) }
        try await waitFor { PosterFixtureProtocol.counts(for: url).started > 0 }
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        try await waitFor { PosterFixtureProtocol.counts(for: url).cancelled == 1 }
        #expect(try await loader.thumbnail(for: request).width == 192)
        #expect(PosterFixtureProtocol.counts(for: url).started == 2)
    }

    private func waitFor(_ ready: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while !ready() {
            guard ContinuousClock.now < deadline else { throw URLError(.timedOut) }
            try await Task.sleep(for: .milliseconds(1))
        }
    }

    private func fixture() throws -> (PosterThumbnailLoader, URL) {
        let url = try #require(URL(string: "https://poster.example.invalid/\(UUID()).png"))
        let context = try #require(CGContext(data: nil, width: 1024, height: 1536, bitsPerComponent: 8, bytesPerRow: 0,
                                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        context.setFillColor(red: 0.25, green: 0.5, blue: 0.75, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: context.width, height: context.height))
        let image = try #require(context.makeImage())
        let data = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
        PosterFixtureProtocol.register(url, data: data as Data)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [PosterFixtureProtocol.self]
        configuration.urlCache = nil
        return (PosterThumbnailLoader(session: URLSession(configuration: configuration)), url)
    }
}

private final class PosterFixtureProtocol: URLProtocol {
    private struct Fixture {
        let data: Data
        var started = 0
        var cancelled = 0
    }

    private static let lock = NSLock()
    private static var fixtures: [URL: Fixture] = [:]
    private var response: DispatchWorkItem?

    static func register(_ url: URL, data: Data) {
        lock.lock(); defer { lock.unlock() }
        fixtures[url] = Fixture(data: data)
    }

    static func counts(for url: URL) -> (started: Int, cancelled: Int) {
        lock.lock(); defer { lock.unlock() }
        return (fixtures[url]?.started ?? 0, fixtures[url]?.cancelled ?? 0)
    }

    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "poster.example.invalid" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else { return }
        Self.lock.lock()
        Self.fixtures[url]?.started += 1
        let data = Self.fixtures[url]?.data
        Self.lock.unlock()
        guard let data, let reply = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "image/png"]) else {
            client?.urlProtocol(self, didFailWithError: URLError(.resourceUnavailable))
            return
        }
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.client?.urlProtocol(self, didReceive: reply, cacheStoragePolicy: .notAllowed)
            self.client?.urlProtocol(self, didLoad: data)
            self.client?.urlProtocolDidFinishLoading(self)
        }
        response = work
        DispatchQueue.global().asyncAfter(deadline: .now() + .milliseconds(150), execute: work)
    }

    override func stopLoading() {
        response?.cancel()
        guard let url = request.url else { return }
        Self.lock.lock(); defer { Self.lock.unlock() }
        Self.fixtures[url]?.cancelled += 1
    }
}
