//
//  FileThumbnailService.swift
//  Clipboard
//
//  Created by crown on 2026/4/9.
//

import AppKit
import QuickLookThumbnailing
import UniformTypeIdentifiers

@MainActor
final class FileThumbnailService {
    static let shared = FileThumbnailService()

    let maxThumbnailSize: CGFloat = 120
    private let memoryCache = NSCache<NSString, NSImage>()
    private let systemIconCache = NSCache<NSString, NSImage>()
    private var inFlightTasks: [String: Task<NSImage, Never>] = [:]

    private init() {
        memoryCache.countLimit = 50
        memoryCache.totalCostLimit = 6 * 1024 * 1024 // 6 MB
        systemIconCache.countLimit = 30
    }

    func clearCache() {
        for task in inFlightTasks.values {
            task.cancel()
        }
        inFlightTasks.removeAll()
        memoryCache.removeAllObjects()
        systemIconCache.removeAllObjects()
    }

    // MARK: - Thumbnail generation

    func generateThumbnail(for fileURL: URL) async -> NSImage {
        let key = fileURL.absoluteString as NSString
        if let cached = memoryCache.object(forKey: key) {
            return cached
        }

        let taskKey = fileURL.absoluteString
        if let existing = inFlightTasks[taskKey] {
            return await existing.value
        }

        let task = Task<NSImage, Never> { [self] in
            let filePath = fileURL.path
            let (exists, repTypes) = await Task.detached(priority: .utility) {
                let exists = FileManager.default.fileExists(atPath: filePath)
                let types = exists ? Self.representationTypes(for: fileURL) : .thumbnail
                return (exists, types)
            }.value
            guard exists, !Task.isCancelled else {
                return systemIcon(for: fileURL)
            }

            let scale = NSScreen.main?.backingScaleFactor ?? 1.0
            let size = NSSize(width: maxThumbnailSize, height: maxThumbnailSize)
            let request = QLThumbnailGenerator.Request(
                fileAt: fileURL,
                size: size,
                scale: scale,
                representationTypes: repTypes
            )
            request.iconMode = true

            let rep = await withTaskCancellationHandler {
                try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request)
            } onCancel: {
                QLThumbnailGenerator.shared.cancel(request)
            }

            let image: NSImage
            if let rep, !Task.isCancelled {
                let nsImage = rep.nsImage
                memoryCache.setObject(
                    nsImage,
                    forKey: key,
                    cost: Int(nsImage.size.width * scale * nsImage.size.height * scale * 4)
                )
                image = nsImage
            } else {
                // 兜底系统图标同样写入缓存，避免不可预览文件重复发起跨进程请求
                let fallback = systemIcon(for: fileURL)
                if !Task.isCancelled {
                    memoryCache.setObject(
                        fallback,
                        forKey: key,
                        cost: Int(maxThumbnailSize * scale * maxThumbnailSize * scale * 4)
                    )
                }
                image = fallback
            }
            return image
        }

        inFlightTasks[taskKey] = task
        defer {
            if inFlightTasks[taskKey] == task {
                inFlightTasks[taskKey] = nil
            }
        }

        return await task.value
    }

    func systemIcon(for fileURL: URL) -> NSImage {
        let extKey = (fileURL.pathExtension.isEmpty ? fileURL.lastPathComponent : fileURL.pathExtension.lowercased()) as NSString
        if let cached = systemIconCache.object(forKey: extKey) {
            return cached
        }

        let icon = NSWorkspace.shared.icon(forFile: fileURL.path)
        let result: NSImage
        if icon.size.width == maxThumbnailSize && icon.size.height == maxThumbnailSize {
            result = icon
        } else {
            let targetSize = NSSize(width: maxThumbnailSize, height: maxThumbnailSize)
            result = NSImage(size: targetSize, flipped: false) { rect in
                icon.draw(in: rect)
                return true
            }
        }

        systemIconCache.setObject(result, forKey: extKey)
        return result
    }

    // MARK: - Private

    nonisolated private static func representationTypes(for fileURL: URL) -> QLThumbnailGenerator.Request.RepresentationTypes {
        guard let contentType = try? fileURL.resourceValues(forKeys: [.contentTypeKey]).contentType else {
            return .thumbnail
        }
        if contentType.conforms(to: .image) {
            return .thumbnail
        }
        if contentType.conforms(to: .text) || contentType.conforms(to: .pdf)
            || contentType.conforms(to: .rtf) || contentType.conforms(to: .sourceCode)
        {
            return [.thumbnail, .icon]
        }
        if contentType.conforms(to: .folder) {
            return .icon
        }
        return .thumbnail
    }
}
