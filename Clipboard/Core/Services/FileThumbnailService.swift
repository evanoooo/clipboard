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
        memoryCache.countLimit = 100
        memoryCache.totalCostLimit = 20 * 1024 * 1024
        systemIconCache.countLimit = 60
    }

    func clearCache() {
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
            guard FileManager.default.fileExists(atPath: fileURL.path) else {
                return systemIcon(for: fileURL)
            }

            let scale = NSScreen.main?.backingScaleFactor ?? 1.0
            let size = NSSize(width: maxThumbnailSize, height: maxThumbnailSize)
            let request = QLThumbnailGenerator.Request(
                fileAt: fileURL,
                size: size,
                scale: scale,
                representationTypes: representationTypes(for: fileURL)
            )
            request.iconMode = true

            let image: NSImage
            if let rep = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request) {
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
                memoryCache.setObject(
                    fallback,
                    forKey: key,
                    cost: Int(maxThumbnailSize * scale * maxThumbnailSize * scale * 4)
                )
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
            let resized = NSImage(size: NSSize(width: maxThumbnailSize, height: maxThumbnailSize))
            resized.lockFocus()
            icon.draw(in: NSRect(x: 0, y: 0, width: maxThumbnailSize, height: maxThumbnailSize))
            resized.unlockFocus()
            result = resized
        }

        systemIconCache.setObject(result, forKey: extKey)
        return result
    }

    // MARK: - Private

    private func representationTypes(for fileURL: URL) -> QLThumbnailGenerator.Request.RepresentationTypes {
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
