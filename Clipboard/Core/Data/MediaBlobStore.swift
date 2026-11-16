//
//  MediaBlobStore.swift
//  Clipboard
//
//  外部内容寻址媒体存储（CAS）：将图片二进制从 SQLite BLOB 剥离至 .media/blobs/<2位前缀>/<sha256>.<ext>
//

import CryptoKit
import Foundation

nonisolated final class MediaBlobStore: @unchecked Sendable {
    nonisolated static let shared = MediaBlobStore()

    private let fm = FileManager.default

    private init() {}

    nonisolated var mediaRootURL: URL {
        let dbURL = URL(fileURLWithPath: PasteSQLManager.databasePath)
        return dbURL.deletingLastPathComponent().appending(path: ".media", directoryHint: .isDirectory)
    }

    nonisolated var blobsRootURL: URL {
        mediaRootURL.appending(path: "blobs", directoryHint: .isDirectory)
    }

    nonisolated private var tempRootURL: URL {
        mediaRootURL.appending(path: "tmp", directoryHint: .isDirectory)
    }

    nonisolated static func fileExtension(for typeRawValue: String) -> String {
        switch typeRawValue.lowercased() {
        case "public.png", "image/png":
            return "png"
        case "public.tiff", "image/tiff":
            return "tiff"
        default:
            return "bin"
        }
    }

    /// 原子写入 CAS 文件，自动去重。返回相对 `blobs/` 的路径与字节大小。
    nonisolated func writeBlob(data: Data, typeRawValue: String) -> (relPath: String, size: Int64)? {
        guard !data.isEmpty else { return nil }
        let hash = data.sha256Hex
        let prefix = String(hash.prefix(2))
        let ext = Self.fileExtension(for: typeRawValue)
        let relPath = "\(prefix)/\(hash).\(ext)"
        let targetURL = blobsRootURL.appending(path: relPath)
        let expectedSize = Int64(data.count)

        if let attrs = try? fm.attributesOfItem(atPath: targetURL.path),
           let existingSize = attrs[.size] as? Int64,
           existingSize == expectedSize {
            return (relPath, expectedSize)
        }

        do {
            try fm.createDirectory(
                at: targetURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try fm.createDirectory(at: tempRootURL, withIntermediateDirectories: true)

            let tmpURL = tempRootURL.appending(path: "\(UUID().uuidString).tmp")
            try data.write(to: tmpURL, options: .atomic)

            if fm.fileExists(atPath: targetURL.path) {
                try? fm.removeItem(at: tmpURL)
            } else {
                try fm.moveItem(at: tmpURL, to: targetURL)
            }
            return (relPath, expectedSize)
        } catch {
            Log.storage.error("写入外部 CAS 媒体失败：\(error)")
            return nil
        }
    }

    /// 根据相对路径读取完整媒体二进制
    nonisolated func readBlob(relPath: String) -> Data? {
        guard !relPath.isEmpty else { return nil }
        let url = blobsRootURL.appending(path: relPath)
        return try? Data(contentsOf: url, options: .mappedIfSafe)
    }

    /// 返回可用于 CGImageSourceCreateWithURL 零拷贝流式解码的本地文件 URL
    nonisolated func blobURL(for relPath: String) -> URL? {
        guard !relPath.isEmpty else { return nil }
        let url = blobsRootURL.appending(path: relPath)
        guard fm.fileExists(atPath: url.path) else { return nil }
        return url
    }

    /// 统计 `.media/blobs/` 目录当前物理磁盘占用
    nonisolated func totalMediaDiskBytes() -> Int64 {
        let root = blobsRootURL
        guard fm.fileExists(atPath: root.path),
              let enumerator = fm.enumerator(
                  at: root,
                  includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
                  options: [.skipsHiddenFiles]
              ) else {
            return 0
        }
        var total: Int64 = 0
        for case let fileURL as URL in enumerator {
            guard let values = try? fileURL.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
                  values.isRegularFile == true,
                  let size = values.fileSize else {
                continue
            }
            total += Int64(size)
        }
        return total
    }

    /// 延迟垃圾回收：清理数据库不再引用且修改时间超过宽限期（默认 24 小时，保护 ⌘Z 撤销）的孤儿文件
    @discardableResult
    nonisolated func purgeOrphanBlobs(
        referencedPaths: Set<String>,
        gracePeriod: TimeInterval = 86_400
    ) -> Int {
        let root = blobsRootURL
        guard fm.fileExists(atPath: root.path),
              let enumerator = fm.enumerator(
                  at: root,
                  includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey],
                  options: [.skipsHiddenFiles]
              ) else {
            return 0
        }
        let cutoffDate = Date().addingTimeInterval(-gracePeriod)
        let rootPath = root.standardizedFileURL.path
        var deletedCount = 0

        for case let fileURL as URL in enumerator {
            guard let values = try? fileURL.resourceValues(forKeys: [.isRegularFileKey, .contentModificationDateKey]),
                  values.isRegularFile == true else {
                continue
            }
            let fullPath = fileURL.standardizedFileURL.path
            guard fullPath.hasPrefix(rootPath + "/") else { continue }
            let relPath = String(fullPath.dropFirst(rootPath.count + 1))

            guard !referencedPaths.contains(relPath) else { continue }
            if let modified = values.contentModificationDate, modified > cutoffDate {
                continue
            }
            if (try? fm.removeItem(at: fileURL)) != nil {
                deletedCount += 1
            }
        }
        return deletedCount
    }
}
