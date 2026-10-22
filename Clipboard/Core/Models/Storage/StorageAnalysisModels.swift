//
//  StorageAnalysisModels.swift
//  Clipboard
//
//  存储健康、用量与大项分析的纯领域模型
//

import AppKit
import Foundation
import SwiftUI

// MARK: - 存储用量与健康统计

struct StorageDiskUsage: Sendable, Equatable {
    let mainDbBytes: Int64
    let walBytes: Int64
    let shmBytes: Int64
    let totalDiskBytes: Int64
    let reclaimableFreeBytes: Int64
    let totalItemCount: Int

    var formattedTotalDisk: String {
        ByteCountFormatter.string(fromByteCount: totalDiskBytes, countStyle: .file)
    }

    var formattedReclaimable: String {
        ByteCountFormatter.string(fromByteCount: reclaimableFreeBytes, countStyle: .file)
    }

    var reclaimableRatio: Double {
        guard totalDiskBytes > 0 else { return 0 }
        return Double(reclaimableFreeBytes) / Double(totalDiskBytes)
    }
}

// MARK: - 数据类型空间分布

struct StorageTypeProportion: Sendable, Identifiable, Equatable {
    var id: String { typeName }
    let typeName: String
    let displayName: String
    let count: Int
    let totalBytes: Int64
    let color: NSColor

    var formattedBytes: String {
        ByteCountFormatter.string(fromByteCount: totalBytes, countStyle: .file)
    }

    var swiftUIColor: Color {
        Color(nsColor: color)
    }
}

// MARK: - 单条大文件元数据摘要

struct StorageItemSummary: Sendable, Identifiable, Equatable {
    let id: Int64
    let uniqueId: String
    let type: String
    let timestamp: Int64
    let appID: Int64
    let appName: String?
    let tag: String?
    let group: Int
    let byteSize: Int64
    let summary: String

    public static let standardTypeTags: Set<String> = [
        "string", "image", "rich", "color", "file", "link", "unknown"
    ]

    /// 是否受机制级保护（加星收藏或绑定分类标签）
    var isProtected: Bool {
        if group != -1 { return true }
        if let tag, !tag.isEmpty, !Self.standardTypeTags.contains(tag.lowercased()) {
            return true
        }
        return false
    }

    var formattedSize: String {
        ByteCountFormatter.string(fromByteCount: byteSize, countStyle: .file)
    }

    var formattedDate: String {
        let interval: TimeInterval = timestamp > 10_000_000_000
            ? TimeInterval(timestamp) / 1000.0
            : TimeInterval(timestamp)
        let date = Date(timeIntervalSince1970: interval)
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }

    var friendlyTypeName: String {
        let lower = type.lowercased()
        if lower.contains("png") { return "PNG 图片" }
        if lower.contains("tiff") { return "TIFF 截图" }
        if lower.contains("jpeg") || lower.contains("jpg") { return "JPEG 照片" }
        if lower.contains("image") { return "图片" }
        if lower.contains("rtf") { return "RTF 富文本" }
        if lower.contains("html") { return "HTML 网页" }
        if lower.contains("utf8") || lower.contains("text") || lower == "string" { return "纯文本" }
        if lower.contains("file") { return "文件" }
        if lower.contains("url") || lower.contains("link") { return "链接" }
        return type.capitalized
    }

    var displaySummary: String {
        let trimmed = summary.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || trimmed.lowercased().starts(with: "[public.") {
            return "[\(friendlyTypeName)]"
        }
        return trimmed
    }

    var typeIconAndColor: (icon: String, color: Color) {
        let lower = type.lowercased()
        if lower.contains("png") || lower.contains("tiff") || lower.contains("jpeg") || lower.contains("image") {
            return ("photo.fill", Color(nsColor: NSColor(red: 0.60, green: 0.35, blue: 0.90, alpha: 1.0)))
        } else if lower.contains("rtf") || lower.contains("html") || lower == "rich" {
            return ("doc.richtext.fill", Color(nsColor: NSColor(red: 0.15, green: 0.45, blue: 0.95, alpha: 1.0)))
        } else if lower.contains("utf8") || lower.contains("text") || lower == "string" {
            return ("text.alignleft", Color(nsColor: NSColor(red: 0.18, green: 0.68, blue: 0.78, alpha: 1.0)))
        } else if lower.contains("file") {
            return ("folder.fill", Color.orange)
        } else if lower.contains("url") || lower.contains("link") {
            return ("link", Color.green)
        } else if lower.contains("color") {
            return ("paintpalette.fill", Color.pink)
        } else {
            return ("doc.fill", Color.secondary)
        }
    }
}

// MARK: - 预设建议筛选器

enum StoragePresetFilter: String, CaseIterable, Identifiable {
    case all = "全部大项"
    case largeImages = "大图 (>5MB)"
    case oldUnstarredImages = "30天前未收藏旧图"
    case largeRichText = "大型富文本"

    var id: String { rawValue }
}
