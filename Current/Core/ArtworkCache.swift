import SwiftUI
import CryptoKit
import ImageIO

/// Shared by lists, the player and system Now Playing. Public artwork only.
actor ArtworkCache {
    static let shared = ArtworkCache()
    // NSCache synchronizes reads and writes, including the synchronous UI lookup.
    private nonisolated(unsafe) let memory = NSCache<NSURL, UIImage>()
    private let directory: URL
    private let session: URLSession
    private let diskLimit: Int
    private var requests: [URL: Task<UIImage?, Never>] = [:]

    init(directory: URL = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Current/Artwork"), session: URLSession = .shared, diskLimit: Int = 128 * 1024 * 1024) {
        self.directory = directory; self.session = session; self.diskLimit = diskLimit
        memory.countLimit = 300
        memory.totalCostLimit = 64 * 1024 * 1024
    }

    nonisolated static func url(_ source: URL?, pixels: Int) -> URL? {
        guard let source, var parts = URLComponents(url: source, resolvingAgainstBaseURL: false) else { return nil }
        if parts.host?.hasSuffix(".music.126.net") == true {
            var items = parts.queryItems?.filter { $0.name != "param" } ?? []
            items.append(URLQueryItem(name: "param", value: "\(pixels)y\(pixels)"))
            parts.queryItems = items
        }
        return parts.url
    }

    nonisolated func cachedImage(for url: URL) -> UIImage? { memory.object(forKey: url as NSURL) }

    func preview(for url: URL) -> UIImage? {
        for candidate in [url] + [1024, 768, 160].compactMap({ Self.url(url, pixels: $0) }) {
            if let image = cachedImage(for: candidate) { return image }
            if let data = try? Data(contentsOf: file(for: candidate)), let image = decode(data, url: candidate) {
                remember(image, for: candidate)
                return image
            }
        }
        return nil
    }

    func image(for url: URL) async -> UIImage? {
        if let image = cachedImage(for: url) { return image }
        if let task = requests[url] { return await task.value }
        let task = Task<UIImage?, Never> {
            let file = file(for: url)
            if let data = try? Data(contentsOf: file), let image = decode(data, url: url) {
                remember(image, for: url)
                return image
            }
            guard let (data, response) = try? await session.data(from: url),
                  let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
                  let image = decode(data, url: url) else { return nil }
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try? data.write(to: file, options: .atomic)
            trimDisk()
            remember(image, for: url)
            return image
        }
        requests[url] = task
        let image = await task.value
        requests[url] = nil
        return image
    }

    private func file(for url: URL) -> URL {
        let key = SHA256.hash(data: Data(url.absoluteString.utf8)).map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent(key)
    }

    private func decode(_ data: Data, url: URL) -> UIImage? {
        let param = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "param" }?.value
        let size = param?.split(separator: "y").first.flatMap { Int($0) } ?? 1024
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceShouldCacheImmediately: true,
                kCGImageSourceThumbnailMaxPixelSize: max(1, min(size, 1024))
              ] as CFDictionary) else { return nil }
        return UIImage(cgImage: image)
    }

    private func remember(_ image: UIImage, for url: URL) {
        memory.setObject(image, forKey: url as NSURL, cost: (image.cgImage?.bytesPerRow ?? 0) * (image.cgImage?.height ?? 0))
    }

    private func trimDisk() {
        let keys: Set<URLResourceKey> = [.fileSizeKey, .contentModificationDateKey]
        guard let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: Array(keys)) else { return }
        let entries = files.compactMap { url -> (URL, Int, Date)? in
            guard let values = try? url.resourceValues(forKeys: keys) else { return nil }
            return (url, values.fileSize ?? 0, values.contentModificationDate ?? .distantPast)
        }
        var bytes = entries.reduce(0) { $0 + $1.1 }
        for entry in entries.sorted(by: { $0.2 < $1.2 }) where bytes > diskLimit {
            if (try? FileManager.default.removeItem(at: entry.0)) != nil { bytes -= entry.1 }
        }
    }
}

struct CachedArtwork<Placeholder: View>: View {
    let url: URL?
    @ViewBuilder var placeholder: () -> Placeholder
    @State private var loadedURL: URL?
    @State private var image: UIImage?

    var body: some View {
        let cached = url.flatMap { ArtworkCache.shared.cachedImage(for: $0) }
        ZStack {
            placeholder()
            if let image = cached ?? (loadedURL == url ? image : nil) {
                Image(uiImage: image).resizable().scaledToFill()
            }
        }
        .task(id: url) {
            image = nil; loadedURL = url
            guard let url else { return }
            if let cached = ArtworkCache.shared.cachedImage(for: url) { image = cached; return }
            let preview = await ArtworkCache.shared.preview(for: url)
            guard !Task.isCancelled else { return }
            image = preview
            let result = await ArtworkCache.shared.image(for: url)
            guard !Task.isCancelled else { return }
            image = result ?? preview
        }
    }
}
