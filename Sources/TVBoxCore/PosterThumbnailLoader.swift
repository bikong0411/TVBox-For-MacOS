import CoreGraphics
import Foundation
import ImageIO

public struct PosterThumbnailRequest: Hashable, Sendable {
    public let url: URL
    public let pixelWidth: Int
    public let pixelHeight: Int

    public init?(url: URL, size: CGSize, scale: CGFloat) {
        let width = size.width * scale
        let height = size.height * scale
        guard width.isFinite, height.isFinite, width > 0, height > 0 else { return nil }
        self.url = url
        // Nearby window sizes share a cache entry when the grid resizes.
        pixelWidth = Self.bucket(width)
        pixelHeight = Self.bucket(height)
    }

    private static func bucket(_ pixels: CGFloat) -> Int {
        Int((min(pixels, 1_536) / 64).rounded(.up)) * 64
    }

    fileprivate var cacheKey: NSString { "\(pixelWidth)x\(pixelHeight) \(url.absoluteString)" as NSString }
}

public actor PosterThumbnailLoader {
    public static let shared = PosterThumbnailLoader()
    private final class CachedThumbnail {
        let image: CGImage
        let expires = ContinuousClock.now.advanced(by: .seconds(300))

        init(_ image: CGImage) { self.image = image }
    }

    private struct Waiter {
        let request: PosterThumbnailRequest
        let continuation: CheckedContinuation<CGImage, Error>
    }

    private struct Download {
        let id: UUID
        let task: Task<Void, Never>
        var waiters: [UUID: Waiter]
    }

    private let session: URLSession
    private let thumbnails = NSCache<NSString, CachedThumbnail>()
    private var downloads: [URL: Download] = [:]

    public init(session: URLSession = .shared) {
        self.session = session
        thumbnails.totalCostLimit = 64 * 1024 * 1024
        thumbnails.countLimit = 200
    }

    public func thumbnail(for request: PosterThumbnailRequest) async throws -> CGImage {
        try Task.checkCancellation()
        if let cached = thumbnails.object(forKey: request.cacheKey), cached.expires > ContinuousClock.now {
            return cached.image
        }

        let waiterID = UUID()
        let image: CGImage = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                guard !Task.isCancelled else {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                let waiter = Waiter(request: request, continuation: continuation)
                if downloads[request.url] != nil {
                    downloads[request.url]?.waiters[waiterID] = waiter
                    return
                }
                let id = UUID()
                let task = Task {
                    do {
                        let data = try await imageData(at: request.url)
                        try Task.checkCancellation()
                        finish(.success(data), url: request.url, id: id)
                    } catch {
                        finish(.failure(error), url: request.url, id: id)
                    }
                }
                downloads[request.url] = Download(id: id, task: task, waiters: [waiterID: waiter])
            }
        } onCancel: {
            Task { await self.cancel(waiterID, url: request.url) }
        }
        try Task.checkCancellation()
        return image
    }

    private func imageData(at url: URL) async throws -> Data {
        if url.isFileURL { return try Data(contentsOf: url, options: .mappedIfSafe) }
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw URLError(.badServerResponse)
        }
        return data
    }

    private func cancel(_ waiterID: UUID, url: URL) {
        guard let waiter = downloads[url]?.waiters.removeValue(forKey: waiterID) else { return }
        if downloads[url]?.waiters.isEmpty == true { downloads.removeValue(forKey: url)?.task.cancel() }
        waiter.continuation.resume(throwing: CancellationError())
    }

    private func finish(_ result: Result<Data, Error>, url: URL, id: UUID) {
        guard downloads[url]?.id == id, let download = downloads.removeValue(forKey: url) else { return }
        // Each URL is fetched once even when the grid and the detail view need
        // different dimensions. Decode each requested size once, off the UI actor.
        let groups = Dictionary(grouping: download.waiters.values, by: \.request)
        for (request, waiters) in groups {
            let thumbnail = result.flatMap { data in Result {
                guard let image = Self.decode(data, for: request) else {
                    throw URLError(.cannotDecodeContentData)
                }
                thumbnails.setObject(CachedThumbnail(image), forKey: request.cacheKey, cost: image.bytesPerRow * image.height)
                return image
            } }
            for waiter in waiters { waiter.continuation.resume(with: thumbnail) }
        }
    }

    private static func decode(_ data: Data, for request: PosterThumbnailRequest) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary) else { return nil }
        let index = CGImageSourceGetPrimaryImageIndex(source)
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Double, width > 0,
              let height = properties[kCGImagePropertyPixelHeight] as? Double, height > 0 else { return nil }
        let orientation = properties[kCGImagePropertyOrientation] as? Int ?? 1
        let rotated = (5...8).contains(orientation)
        let scale = max(Double(request.pixelWidth) / (rotated ? height : width),
                        Double(request.pixelHeight) / (rotated ? width : height))
        let longestEdge = max(width, height)
        let maxPixels = min(1_536, min(1, scale) * longestEdge).rounded(.up)
        return CGImageSourceCreateThumbnailAtIndex(source, index, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixels
        ] as CFDictionary)
    }
}
