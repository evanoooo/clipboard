//
//  PasteMigrationModels.swift
//  Clipboard
//
//  Created by crown on 2026/10/23.
//

import Foundation

/// 扫描 Paste.app 数据库后的预检信息
nonisolated public struct PasteMigrationScanInfo: Sendable, Equatable {
    public let databaseURL: URL
    public let totalItemCount: Int
    public let sourceAppCount: Int
    public let earliestDate: Date?
    public let latestDate: Date?
    public let databaseSizeBytes: Int64

    public var formattedSize: String {
        ByteCountFormatter.string(fromByteCount: databaseSizeBytes, countStyle: .file)
    }

    public var formattedDateRange: String {
        guard let earliest = earliestDate, let latest = latestDate else {
            return "-"
        }
        return "\(earliest.formatted(date: .abbreviated, time: .omitted)) ~ \(latest.formatted(date: .abbreviated, time: .omitted))"
    }

    public nonisolated init(
        databaseURL: URL,
        totalItemCount: Int,
        sourceAppCount: Int,
        earliestDate: Date?,
        latestDate: Date?,
        databaseSizeBytes: Int64
    ) {
        self.databaseURL = databaseURL
        self.totalItemCount = totalItemCount
        self.sourceAppCount = sourceAppCount
        self.earliestDate = earliestDate
        self.latestDate = latestDate
        self.databaseSizeBytes = databaseSizeBytes
    }
}

/// 迁移进度信息
nonisolated public struct PasteMigrationProgress: Sendable {
    public let current: Int
    public let total: Int
    public let importedCount: Int
    public let duplicateCount: Int
    public let skippedCount: Int
    public let statusMessage: String

    public var fractionCompleted: Double {
        guard total > 0 else { return 0 }
        return min(max(Double(current) / Double(total), 0.0), 1.0)
    }

    public nonisolated init(
        current: Int,
        total: Int,
        importedCount: Int,
        duplicateCount: Int,
        skippedCount: Int,
        statusMessage: String
    ) {
        self.current = current
        self.total = total
        self.importedCount = importedCount
        self.duplicateCount = duplicateCount
        self.skippedCount = skippedCount
        self.statusMessage = statusMessage
    }
}

/// 迁移完成统计结果
nonisolated public struct PasteMigrationResult: Sendable {
    public let isSuccess: Bool
    public let importedCount: Int
    public let duplicateCount: Int
    public let skippedCount: Int
    public let autoBackupURL: URL?
    public let errorMessage: String?

    public nonisolated init(
        isSuccess: Bool,
        importedCount: Int = 0,
        duplicateCount: Int = 0,
        skippedCount: Int = 0,
        autoBackupURL: URL? = nil,
        errorMessage: String? = nil
    ) {
        self.isSuccess = isSuccess
        self.importedCount = importedCount
        self.duplicateCount = duplicateCount
        self.skippedCount = skippedCount
        self.autoBackupURL = autoBackupURL
        self.errorMessage = errorMessage
    }
}
