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

nonisolated struct StorageDiskUsage: Sendable, Equatable {
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

nonisolated struct StorageItemSummary: Sendable, Identifiable, Equatable {
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
        return date.formatted(date: .numeric, time: .shortened)
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

nonisolated enum StoragePresetFilter: String, CaseIterable, Identifiable, Sendable {
    case all = "全部大项"
    case oneMonthUnstarredImages = "1 个月前未收藏旧图"
    case threeMonthsUnstarredImages = "3 个月前未收藏旧图"
    case sixMonthsUnstarredImages = "6 个月前未收藏旧图"
    case largeImages = "大图 (> 5 MB)"
    case largeRichText = "大型富文本 (> 1 MB)"

    var id: String { rawValue }
}

// MARK: - 软配额与智能老化淘汰模型

nonisolated enum SoftQuotaThreshold: Int64, CaseIterable, Identifiable, Sendable {
    case mb500 = 500_000_000        // 500 MB (严格 1000 进制对齐 macOS .file 格式化)
    case gb1 = 1_000_000_000        // 1 GB
    case gb2 = 2_000_000_000        // 2 GB
    case unlimited = 0              // 不限

    var id: Int64 { rawValue }

    var displayName: String {
        switch self {
        case .mb500: return "500 MB (推荐)"
        case .gb1: return "1 GB (适中)"
        case .gb2: return "2 GB (充裕)"
        case .unlimited: return "不设限制"
        }
    }
}

nonisolated enum SoftQuotaAgingPolicy: String, CaseIterable, Identifiable, Sendable {
    case oneMonth = "one_month"
    case threeMonths = "three_months"
    case sixMonths = "six_months"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .oneMonth: return "1 个月前未收藏旧图"
        case .threeMonths: return "3 个月前未收藏旧图 (推荐)"
        case .sixMonths: return "6 个月前未收藏旧图"
        }
    }

    var days: Int {
        switch self {
        case .oneMonth: return 30
        case .threeMonths: return 90
        case .sixMonths: return 180
        }
    }
}

nonisolated struct StorageQuotaStatus: Sendable, Equatable {
    let currentBytes: Int64
    let quotaBytes: Int64
    let candidateItemCount: Int
    let candidateFreedBytes: Int64

    var isEnabled: Bool { quotaBytes > 0 }

    var ratio: Double {
        guard quotaBytes > 0 else { return 0 }
        return Double(currentBytes) / Double(quotaBytes)
    }

    var isExceeded: Bool {
        quotaBytes > 0 && currentBytes >= quotaBytes
    }

    var isWarning: Bool {
        quotaBytes > 0 && ratio >= 0.85
    }

    var formattedCurrent: String {
        ByteCountFormatter.string(fromByteCount: currentBytes, countStyle: .file)
    }

    var formattedQuota: String {
        quotaBytes > 0 ? ByteCountFormatter.string(fromByteCount: quotaBytes, countStyle: .file) : "不限"
    }

    var formattedCandidateFreed: String {
        ByteCountFormatter.string(fromByteCount: candidateFreedBytes, countStyle: .file)
    }
}


// MARK: - SQLite 内存映射上限模型

nonisolated enum SQLiteMmapThreshold: Int, CaseIterable, Identifiable, Sendable {
    case disabled = 0
    case mb32 = 32
    case mb64 = 64
    case mb128 = 128
    case mb256 = 256
    case mb512 = 512
    case mb666 = 666
    case gb1 = 1024
    case gb2 = 2048

    var id: Int { rawValue }

    var displayName: String {
        switch self {
        case .disabled: return "0 MB (关闭映射 · 推荐)"
        case .mb32: return "32 MB (轻量)"
        case .mb64: return "64 MB (平衡)"
        case .mb128: return "128 MB (极速检索)"
        case .mb256: return "256 MB (高性能)"
        case .mb512: return "512 MB (极限)"
        case .mb666: return "666 MB"
        case .gb1: return "1 GB (1024 MB)"
        case .gb2: return "2 GB (2048 MB)"
        }
    }

    var bytes: Int64 {
        Int64(rawValue) * 1024 * 1024
    }
}
