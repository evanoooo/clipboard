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

                let displayName: String
                let color: NSColor
                switch typeStr {
                case "image":
                    displayName = String(localized: "Image")
                    color = .systemPurple
                case "rich":
                    displayName = String(localized: "Rich Text", defaultValue: "富文本")
                    color = .systemBlue
                case "string":
                    displayName = String(localized: "Text")
                    color = .systemTeal
                case "color":
                    displayName = String(localized: "Color")
                    color = .systemOrange
                case "file":
                    displayName = String(localized: "File")
                    color = .systemYellow
                case "link":
                    displayName = String(localized: "Link")
                    color = .systemGreen
                default:
                    displayName = typeStr.capitalized
                    color = .systemGray
                }

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

    /// 获取占用空间最大的 Top N 条目
    func getTopStorageItems(limit: Int = 100, filter: StoragePresetFilter = .all) -> [StorageItemSummary] {
        guard let connection else { return [] }
        var list: [StorageItemSummary] = []

        var whereClause = "WHERE 1=1"
        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
        let thirtyDaysAgoMs = nowMs - (30 * 24 * 60 * 60 * 1000)

        switch filter {
        case .all:
            break
        case .largeImages:
            whereClause += " AND type = 'image' AND LENGTH(data) > 5242880"
        case .oldUnstarredImages:
            whereClause += " AND type = 'image' AND timestamp < \(thirtyDaysAgoMs) AND (`group` IS NULL OR `group` = -1) AND (tag IS NULL OR tag = '')"
        case .largeRichText:
            whereClause += " AND type = 'rich' AND LENGTH(data) > 1048576"
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
