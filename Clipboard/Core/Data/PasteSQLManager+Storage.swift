//
//  PasteSQLManager+Storage.swift
//  Clipboard
//
//  存储健康与空间占用深度分析、用户自主批量清理与 Vacuum 碎片整理
//

import AppKit
import Foundation
import SQLite

extension PasteSQLManager {
    /// 获取 SQLite 物理磁盘占用与碎片空洞统计
    func getStorageDiskUsage() -> StorageDiskUsage {
        let dbPath = Self.databasePath
        let walPath = dbPath + "-wal"
        let shmPath = dbPath + "-shm"
        let fm = FileManager.default

        let dbBytes = (try? fm.attributesOfItem(atPath: dbPath)[.size] as? Int64) ?? 0
        let walBytes = (try? fm.attributesOfItem(atPath: walPath)[.size] as? Int64) ?? 0
        let shmBytes = (try? fm.attributesOfItem(atPath: shmPath)[.size] as? Int64) ?? 0
        let totalDisk = dbBytes + walBytes + shmBytes

        let pageSize = (try? connection?.scalar("PRAGMA page_size") as? Int64) ?? 4096
        let freeListCount = (try? connection?.scalar("PRAGMA freelist_count") as? Int64) ?? 0
        let reclaimable = freeListCount * pageSize

        let totalCount = (try? connection?.scalar(table.count)) ?? 0

        return StorageDiskUsage(
            mainDbBytes: dbBytes,
            walBytes: walBytes,
            shmBytes: shmBytes,
            totalDiskBytes: totalDisk,
            reclaimableFreeBytes: reclaimable,
            totalItemCount: totalCount
        )
    }

    /// 获取按类型分布的体积占比
    func getStorageTypeProportions() -> [StorageTypeProportion] {
        guard let connection else { return [] }
        var list: [StorageTypeProportion] = []
        let sql = """
            SELECT type, count(*), COALESCE(SUM(LENGTH(data)), 0)
            FROM Clip
            GROUP BY type
            ORDER BY SUM(LENGTH(data)) DESC
        """
        do {
            let stmt = try connection.prepare(sql)
            for row in stmt {
                let typeStr = (row[0] as? String) ?? "unknown"
                let count = Int((row[1] as? Int64) ?? 0)
                let bytes = (row[2] as? Int64) ?? 0
                guard bytes > 0 else { continue }

                let (displayName, color) = Self.typeMetadata(for: typeStr)

                list.append(StorageTypeProportion(
                    typeName: typeStr,
                    displayName: displayName,
                    count: count,
                    totalBytes: bytes,
                    color: color
                ))
            }
        } catch {
            log.error("Failed to query storage type proportions: \(error)")
        }
        return list
    }

    /// 类型友好名称与现代色谱映射
    nonisolated static func typeMetadata(for typeStr: String) -> (displayName: String, color: NSColor) {
        let lower = typeStr.lowercased()
        if lower.contains("png") {
            return ("PNG 图片", NSColor(red: 0.58, green: 0.32, blue: 0.88, alpha: 1.0)) // 现代紫
        } else if lower.contains("tiff") {
            return ("TIFF 截图", NSColor(red: 0.84, green: 0.22, blue: 0.72, alpha: 1.0)) // 亮品红
        } else if lower.contains("jpeg") || lower.contains("jpg") {
            return ("JPEG 照片", NSColor(red: 0.70, green: 0.38, blue: 0.98, alpha: 1.0)) // 兰花紫
        } else if lower.contains("image") {
            return ("图片", NSColor(red: 0.65, green: 0.30, blue: 0.85, alpha: 1.0))
        } else if lower.contains("utf8") || lower.contains("text") || lower == "string" {
            return ("纯文本", NSColor(red: 0.18, green: 0.68, blue: 0.78, alpha: 1.0)) // 活力青
        } else if lower.contains("rtf") {
            return ("RTF 富文本", NSColor(red: 0.12, green: 0.45, blue: 0.95, alpha: 1.0)) // 科技蓝
        } else if lower.contains("html") {
            return ("HTML 网页", NSColor(red: 0.22, green: 0.58, blue: 0.98, alpha: 1.0)) // 天蓝
        } else if lower.contains("file") {
            return ("文件路径", NSColor(red: 0.95, green: 0.62, blue: 0.10, alpha: 1.0)) // 琥珀金
        } else if lower.contains("url") || lower.contains("link") {
            return ("链接", NSColor(red: 0.20, green: 0.78, blue: 0.45, alpha: 1.0)) // 翠绿
        } else if lower.contains("color") {
            return ("颜色值", NSColor(red: 0.98, green: 0.35, blue: 0.48, alpha: 1.0)) // 珊瑚粉
        } else {
            return (typeStr.capitalized, NSColor(red: 0.55, green: 0.58, blue: 0.62, alpha: 1.0)) // 优雅雅灰
        }
    }

    /// 获取占用空间最大的 Top N 条目
    func getTopStorageItems(limit: Int = 100, filter: StoragePresetFilter = .all) -> [StorageItemSummary] {
        guard let connection else { return [] }
        var list: [StorageItemSummary] = []

        var whereClause = "WHERE 1=1"
        let nowSec = Int64(Date().timeIntervalSince1970)
        let thirtyDaysAgoSec = nowSec - (30 * 24 * 60 * 60)
        let thirtyDaysAgoMs = thirtyDaysAgoSec * 1000

        switch filter {
        case .all:
            break
        case .largeImages:
            whereClause += " AND (tag = 'image' OR type LIKE '%png%' OR type LIKE '%tiff%' OR type LIKE '%jpeg%' OR type LIKE '%image%') AND LENGTH(data) > 5242880"
        case .oldUnstarredImages:
            // 兼容秒级 (10位) 或毫秒级 (13位) 时间戳，未加入任何分类标签或加星 (group == -1)
            whereClause += " AND (tag = 'image' OR type LIKE '%png%' OR type LIKE '%tiff%' OR type LIKE '%jpeg%' OR type LIKE '%image%') AND ((timestamp < \(thirtyDaysAgoSec) AND timestamp < 10000000000) OR timestamp < \(thirtyDaysAgoMs)) AND (`group` IS NULL OR `group` = -1)"
        case .largeRichText:
            whereClause += " AND (tag = 'rich' OR type LIKE '%rtf%' OR type LIKE '%html%') AND LENGTH(data) > 1048576"
        }

        let sql = """
            SELECT id, unique_id, type, timestamp, app_id, tag, `group`, LENGTH(data) AS byte_size, SUBSTR(search_text, 1, 100)
            FROM Clip
            \(whereClause)
            ORDER BY byte_size DESC
            LIMIT \(limit)
        """

        do {
            let stmt = try connection.prepare(sql)
            for row in stmt {
                guard let id = row[0] as? Int64 else { continue }
                let uniqueId = (row[1] as? String) ?? ""
                let type = (row[2] as? String) ?? "string"
                let timestamp = (row[3] as? Int64) ?? 0
                let appId = (row[4] as? Int64) ?? 0
                let tag = row[5] as? String
                let group = Int((row[6] as? Int64) ?? -1)
                let byteSize = (row[7] as? Int64) ?? 0
                let summary = (row[8] as? String) ?? ""
                let appName = apps[appId]?.name

                list.append(StorageItemSummary(
                    id: id,
                    uniqueId: uniqueId,
                    type: type,
                    timestamp: timestamp,
                    appID: appId,
                    appName: appName,
                    tag: tag,
                    group: group,
                    byteSize: byteSize,
                    summary: summary.trimmingCharacters(in: .whitespacesAndNewlines)
                ))
            }
        } catch {
            log.error("Failed to query top storage items: \(error)")
        }
        return list
    }

    /// 用户主动勾选批量删除选中的大体积条目
    func deleteStorageItems(ids: [Int64]) -> Int64 {
        guard let connection, !ids.isEmpty else { return 0 }
        var totalFreedBytes: Int64 = 0

        do {
            let idList = ids.map(String.init).joined(separator: ",")
            let sumSql = "SELECT COALESCE(SUM(LENGTH(data)), 0) FROM Clip WHERE id IN (\(idList))"
            if let sumStmt = try? connection.prepare(sumSql), let row = sumStmt.makeIterator().next() {
                totalFreedBytes = (row[0] as? Int64) ?? 0
            }

            try connection.transaction {
                try connection.execute("DELETE FROM Clip WHERE id IN (\(idList))")
            }
        } catch {
            log.error("Failed to delete storage items: \(error)")
        }
        return totalFreedBytes
    }

    /// 压缩并整理数据库碎片（VACUUM），真正将磁盘空间释放归还给 macOS
    func vacuumDatabase() throws -> (beforeBytes: Int64, afterBytes: Int64) {
        guard let connection else {
            return (0, 0)
        }
        let fm = FileManager.default
        let dbPath = Self.databasePath
        let walPath = dbPath + "-wal"

        let beforeBytes = ((try? fm.attributesOfItem(atPath: dbPath)[.size] as? Int64) ?? 0)
            + ((try? fm.attributesOfItem(atPath: walPath)[.size] as? Int64) ?? 0)

        // 1. 将 WAL 日志 checkpoint 归档入主库
        try? connection.execute("PRAGMA wal_checkpoint(TRUNCATE)")
        // 2. 执行全量 VACUUM 释放 Free Pages
        try connection.execute("VACUUM")
        // 3. 再次将 VACUUM 产生的日志刷入并截断
        try? connection.execute("PRAGMA wal_checkpoint(TRUNCATE)")

        let afterBytes = ((try? fm.attributesOfItem(atPath: dbPath)[.size] as? Int64) ?? 0)
            + ((try? fm.attributesOfItem(atPath: walPath)[.size] as? Int64) ?? 0)

        return (beforeBytes, afterBytes)
    }
}
