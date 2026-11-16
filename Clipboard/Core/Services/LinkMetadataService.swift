//
//  LinkMetadataService.swift
//  Clipboard
//
//  统一管理网络链接预览元数据抓取、内存/磁盘两级缓存、失败负缓存与并发限流
//

import AppKit
import CryptoKit
@preconcurrency import LinkPresentation
import UniformTypeIdentifiers

@MainActor
final class LinkMetadataService {
    static let shared = LinkMetadataService()

    /// 内存负缓存：失败 URL 记录时间戳，30 分钟内不重复向外发起网络请求
    private var negativeCache: [String: ContinuousClock.Instant] = [:]
    private static let negativeCacheTTL: Duration = .seconds(1800) // 30 分钟
    private static let maxNegativeCacheEntries = 200

    /// 在途请求去重，防止滚动/并发请求同一 URL 时重复拉取
    private var inFlightTasks: [String: Task<LinkPreviewMetadata, Never>] = [:]

    /// 最大并发抓取数
    private static let maxConcurrentFetches = 2
    private var activeFetchCount = 0
    private var waitingQueue: [CheckedContinuation<Void, Never>] = []

    private let cacheDirectory: URL

    private init() {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL.temporaryDirectory
        let dir = base.appending(path: "LinkMetadata", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        self.cacheDirectory = dir
    }

    /// 获取 URL 的元数据（先查内存/磁盘缓存，若未命中则受控并发抓取）
    func fetchMetadata(for url: URL) async -> LinkPreviewMetadata {
        guard url.isLikelySimpleWebPage else {
            return LinkPreviewMetadata(title: nil, previewImage: nil, iconImage: nil)
        }

        let urlKey = url.absoluteString

        // 1. 检查失败负缓存
        if let failInstant = negativeCache[urlKey] {
            if ContinuousClock.now - failInstant < Self.negativeCacheTTL {
                return LinkPreviewMetadata(title: nil, previewImage: nil, iconImage: nil)
            } else {
                negativeCache.removeValue(forKey: urlKey)
            }
        }

        // 2. 复用内存缓存
        if let memCached = ModelLinkMetadataCache.shared.metadata(for: urlKey) {
            return memCached
        }

        // 3. 在途请求去重
        if let existingTask = inFlightTasks[urlKey] {
            return await existingTask.value
        }

        let task = Task { @MainActor [weak self] () -> LinkPreviewMetadata in
            guard let self else {
                return LinkPreviewMetadata(title: nil, previewImage: nil, iconImage: nil)
            }
            defer {
                if self.inFlightTasks[urlKey] != nil {
                    self.inFlightTasks.removeValue(forKey: urlKey)
                }
            }

            // 4. 检查磁盘缓存
            if let diskCached = await self.loadDiskCache(for: url) {
                ModelLinkMetadataCache.shared.setMetadata(diskCached, for: urlKey)
                return diskCached
            }

            guard !Task.isCancelled else {
                return LinkPreviewMetadata(title: nil, previewImage: nil, iconImage: nil)
            }

            // 5. 并发限流等待
            await self.acquireSlot()
            defer { self.releaseSlot() }

            guard !Task.isCancelled else {
                return LinkPreviewMetadata(title: nil, previewImage: nil, iconImage: nil)
            }

            // 6. 发起实际网络抓取
            let provider = LPMetadataProvider()
            provider.timeout = 5.0
            nonisolated(unsafe) let unsafeProvider = provider

            do {
                let metadata = try await withTaskCancellationHandler {
                    try await provider.startFetchingMetadata(for: url)
                } onCancel: {
                    unsafeProvider.cancel()
                }

                let rawPreview: NSImage? = await Self.loadImage(from: metadata.imageProvider)
                let previewImage = Self.downscaleIfNeeded(rawPreview, maxPixelSize: 600)
                let rawIcon: NSImage? = previewImage == nil
                    ? await Self.loadImage(from: metadata.iconProvider)
                    : nil
                let iconImage = Self.downscaleIfNeeded(rawIcon, maxPixelSize: 128)

                let result = LinkPreviewMetadata(
                    title: metadata.title,
                    previewImage: previewImage,
                    iconImage: iconImage
                )

                ModelLinkMetadataCache.shared.setMetadata(result, for: urlKey)
                self.saveDiskCache(result, for: url)
                return result
            } catch is CancellationError {
                return LinkPreviewMetadata(title: nil, previewImage: nil, iconImage: nil)
            } catch {
                // 取消导致的错误不污染负缓存
                if Task.isCancelled {
                    return LinkPreviewMetadata(title: nil, previewImage: nil, iconImage: nil)
                }
                self.recordNegativeCache(for: urlKey)
                return LinkPreviewMetadata(title: nil, previewImage: nil, iconImage: nil)
            }
        }

        inFlightTasks[urlKey] = task
        return await task.value
    }

    private func recordNegativeCache(for urlKey: String) {
        let now = ContinuousClock.now
        if negativeCache.count >= Self.maxNegativeCacheEntries {
            negativeCache = negativeCache.filter { now - $0.value < Self.negativeCacheTTL }
            if negativeCache.count >= Self.maxNegativeCacheEntries {
                negativeCache.removeAll(keepingCapacity: true)
            }
        }
        negativeCache[urlKey] = now
    }

    // MARK: - 并发控制

    private func acquireSlot() async {
        if activeFetchCount < Self.maxConcurrentFetches {
            activeFetchCount += 1
            return
        }
        await withCheckedContinuation { continuation in
            waitingQueue.append(continuation)
        }
    }

    private func releaseSlot() {
        if !waitingQueue.isEmpty {
            let next = waitingQueue.removeFirst()
            next.resume()
        } else {
            activeFetchCount = max(0, activeFetchCount - 1)
        }
    }

    // MARK: - 磁盘缓存

    private func cacheKey(for url: URL) -> String {
        Data(url.absoluteString.utf8).sha256Hex
    }

    private func loadDiskCache(for url: URL) async -> LinkPreviewMetadata? {
        let key = cacheKey(for: url)
        let jsonURL = cacheDirectory.appending(path: "\(key).json")
        let previewURL = cacheDirectory.appending(path: "\(key)_preview.jpg")
        let iconURL = cacheDirectory.appending(path: "\(key)_icon.png")

        return await Task.detached(priority: .utility) { () -> LinkPreviewMetadata? in
            guard let jsonData = try? Data(contentsOf: jsonURL),
                  let dict = (try? JSONSerialization.jsonObject(with: jsonData)) as? [String: Any],
                  let timestamp = dict["timestamp"] as? TimeInterval
            else { return nil }

            // 7 天 TTL (7 * 86400 = 604,800s)
            if Date().timeIntervalSince1970 - timestamp > 604_800 {
                return nil
            }

            let title = dict["title"] as? String
            let previewImage = (try? Data(contentsOf: previewURL)).flatMap { NSImage(data: $0) }
            let iconImage = (try? Data(contentsOf: iconURL)).flatMap { NSImage(data: $0) }

            return LinkPreviewMetadata(
                title: title,
                previewImage: previewImage,
                iconImage: iconImage
            )
        }.value
    }

    private func saveDiskCache(_ metadata: LinkPreviewMetadata, for url: URL) {
        let key = cacheKey(for: url)
        let jsonURL = cacheDirectory.appending(path: "\(key).json")
        let previewURL = cacheDirectory.appending(path: "\(key)_preview.jpg")
        let iconURL = cacheDirectory.appending(path: "\(key)_icon.png")

        let title = metadata.title
        let timestamp = Date().timeIntervalSince1970
        let previewJpeg: Data? = Self.bitmapRep(from: metadata.previewImage)
            .flatMap { $0.representation(using: .jpeg, properties: [.compressionFactor: 0.7]) }
        let iconPng: Data? = Self.bitmapRep(from: metadata.iconImage)
            .flatMap { $0.representation(using: .png, properties: [:]) }

        Task.detached(priority: .utility) {
            var dict: [String: Any] = ["timestamp": timestamp]
            if let title {
                dict["title"] = title
            }
            if let data = try? JSONSerialization.data(withJSONObject: dict) {
                try? data.write(to: jsonURL, options: .atomic)
            }
            if let previewJpeg {
                try? previewJpeg.write(to: previewURL, options: .atomic)
            }
            if let iconPng {
                try? iconPng.write(to: iconURL, options: .atomic)
            }
        }
    }

    // MARK: - 图片解析与下采样

    private static func bitmapRep(from image: NSImage?) -> NSBitmapImageRep? {
        guard let image else { return nil }
        if let existing = image.representations.first as? NSBitmapImageRep {
            return existing
        }
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return nil
        }
        return NSBitmapImageRep(cgImage: cgImage)
    }

    private static func loadImage(from provider: NSItemProvider?) async -> NSImage? {
        guard let provider, provider.canLoadObject(ofClass: NSImage.self) else {
            return nil
        }
        return await withCheckedContinuation { continuation in
            provider.loadObject(ofClass: NSImage.self) { image, _ in
                continuation.resume(returning: image as? NSImage)
            }
        }
    }

    private static func downscaleIfNeeded(_ image: NSImage?, maxPixelSize: CGFloat) -> NSImage? {
        guard let image else { return nil }
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return image
        }
        let width = CGFloat(cgImage.width)
        let height = CGFloat(cgImage.height)
        let maxDim = max(width, height)
        guard maxDim > maxPixelSize else { return image }

        let scale = maxPixelSize / maxDim
        let targetSize = CGSize(width: width * scale, height: height * scale)

        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(targetSize.width),
            pixelsHigh: Int(targetSize.height),
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        )
        guard let rep else { return image }

        NSGraphicsContext.saveGraphicsState()
        let context = NSGraphicsContext(bitmapImageRep: rep)
        NSGraphicsContext.current = context
        context?.imageInterpolation = .high
        image.draw(
            in: CGRect(origin: .zero, size: targetSize),
            from: .zero,
            operation: .copy,
            fraction: 1.0
        )
        NSGraphicsContext.restoreGraphicsState()

        let downscaled = NSImage(size: targetSize)
        downscaled.addRepresentation(rep)
        return downscaled
    }
}
