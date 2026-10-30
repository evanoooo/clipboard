//
//  PasteSQLManager+Storage.swift
//  Clipboard
//
//  存储健康分析、类型分布统计与大项排查
//

import AppKit
import Foundation
import SQLite

extension PasteSQLManager {
    /// 统计 SQLite 物理磁盘占用与碎片状态
    func getStorageDiskUsage() -> StorageDiskUsage {
        let fm = FileManager.default
        let dbPath = Self.databasePath
        let walPath = dbPath + "-wal"
        let shmPath = dbPath + "-shm"

        let mainDbBytes = (try? fm.attributesOfItem(atPath: dbPath)[.size] as? Int64) ?? 0
        let walBytes = (try? fm.attributesOfItem(atPath: walPath)[.size] as? Int64) ?? 0
        let shmBytes = (try? fm.attributesOfItem(atPath: shmPath)[.size] as? Int64) ?? 0
        let totalDiskBytes = mainDbBytes + walBytes + shmBytes

        var reclaimableFreeBytes: Int64 = 0
        var totalItemCount: Int = 0

        guard let connection else {
            return StorageDiskUsage(
                mainDbBytes: mainDbBytes,
                walBytes: walBytes,
                shmBytes: shmBytes,
                totalDiskBytes: totalDiskBytes,
                reclaimableFreeBytes: 0,
                totalItemCount: 0
            )
        }

        do {
            let pageSize = (try? connection.scalar("PRAGMA page_size") as? Int64) ?? 4096
            let freelistCount = (try? connection.scalar("PRAGMA freelist_count") as? Int64) ?? 0
            reclaimableFreeBytes = freelistCount * pageSize
            totalItemCount = (try? connection.scalar(table.count)) ?? 0
        }

        return StorageDiskUsage(
            mainDbBytes: mainDbBytes,
            walBytes: walBytes,
            shmBytes: shmBytes,
            totalDiskBytes: totalDiskBytes,
            reclaimableFreeBytes: reclaimableFreeBytes,
            totalItemCount: totalItemCount
        )
    }

    /// 获取按数据类型的占用空间分布
    func getStorageTypeProportions() -> [StorageTypeProportion] {
        guard let connection else { return [] }
        var proportions: [StorageTypeProportion] = []

        let sql = """
            SELECT type, COUNT(*) AS count, COALESCE(SUM(LENGTH(data)), 0) AS total_bytes
            FROM Clip
            GROUP BY type
            ORDER BY total_bytes DESC
        """

        do {
            let stmt = try connection.prepare(sql)
            for row in stmt {
                guard let rawType = row[0] as? String else { continue }
                let count = Int((row[1] as? Int64) ?? 0)
                let totalBytes = (row[2] as? Int64) ?? 0

                let (displayName, color) = self.metadataForType(rawType)

                proportions.append(StorageTypeProportion(
                    typeName: rawType,
                    displayName: displayName,
                    count: count,
                    totalBytes: totalBytes,
                    color: color
                ))
            }
        } catch {
            log.error("Failed to query storage type proportions: \(error)")
        }

        return proportions
    }

    private func metadataForType(_ typeStr: String) -> (displayName: String, color: NSColor) {
        let lower = typeStr.lowercased()
        if lower.contains("png") || lower.contains("tiff") || lower.contains("jpeg") || lower.contains("jpg") || lower.contains("image") {
            return ("图片", NSColor(red: 0.65, green: 0.38, blue: 0.95, alpha: 1.0)) // 紫色
        } else if lower.contains("rtf") || lower.contains("html") || lower == "rich" {
            return ("富文本", NSColor(red: 0.20, green: 0.50, blue: 0.98, alpha: 1.0)) // 科技蓝
        } else if lower.contains("utf8") || lower.contains("text") || lower == "string" {
            return ("纯文本", NSColor(red: 0.22, green: 0.74, blue: 0.85, alpha: 1.0)) // 青蓝
        } else if lower.contains("file") {
            return ("文件", NSColor(red: 0.98, green: 0.60, blue: 0.20, alpha: 1.0)) // 暖橙
        } else if lower.contains("url") || lower.contains("link") {
            return ("链接", NSColor(red: 0.20, green: 0.78, blue: 0.45, alpha: 1.0)) // 翠绿
        } else if lower.contains("color") {
            return ("颜色值", NSColor(red: 0.98, green: 0.35, blue: 0.48, alpha: 1.0)) // 珊瑚粉
        } else {
            return (typeStr.capitalized, NSColor(red: 0.55, green: 0.58, blue: 0.62, alpha: 1.0)) // 优雅灰
        }
    }

    /// 获取占用空间最大的 Top N 条目
    func getTopStorageItems(limit: Int = 100, filter: StoragePresetFilter = .all) -> [StorageItemSummary] {
        guard let connection else { return [] }
        var list: [StorageItemSummary] = []

        var whereClause = "WHERE 1=1"
        let nowSec = Int64(Date().timeIntervalSince1970)
        let thirtyDaysAgoSec = nowSec - (30 * 24 * 60 * 60)
        let ninetyDaysAgoSec = nowSec - (90 * 24 * 60 * 60)
        let sixMonthsAgoSec = nowSec - (180 * 24 * 60 * 60)

        switch filter {
        case .all:
            break
        case .oneMonthUnstarredImages:
            // 30天前（1 个月前），未加入任何分类标签或加星 (group == -1 或 group IS NULL)
            whereClause += """
             AND (tag = 'image' OR type LIKE '%png%' OR type LIKE '%tiff%' OR type LIKE '%jpeg%' OR type LIKE '%image%') \
            AND ((CASE WHEN timestamp > 10000000000 THEN timestamp / 1000 ELSE timestamp END) < \(thirtyDaysAgoSec)) \
            AND (`group` IS NULL OR `group` = -1)
            """
        case .threeMonthsUnstarredImages:
            // 90天前（约3 个月前），未加入任何分类标签或加星 (group == -1 或 group IS NULL)
            whereClause += """
             AND (tag = 'image' OR type LIKE '%png%' OR type LIKE '%tiff%' OR type LIKE '%jpeg%' OR type LIKE '%image%') \
            AND ((CASE WHEN timestamp > 10000000000 THEN timestamp / 1000 ELSE timestamp END) < \(ninetyDaysAgoSec)) \
            AND (`group` IS NULL OR `group` = -1)
            """
        case .sixMonthsUnstarredImages:
            // 180天前（约6 个月前），未加入任何分类标签或加星 (group == -1 或 group IS NULL)
            whereClause += """
             AND (tag = 'image' OR type LIKE '%png%' OR type LIKE '%tiff%' OR type LIKE '%jpeg%' OR type LIKE '%image%') \
            AND ((CASE WHEN timestamp > 10000000000 THEN timestamp / 1000 ELSE timestamp END) < \(sixMonthsAgoSec)) \
            AND (`group` IS NULL OR `group` = -1)
            """
        case .largeImages:
            whereClause += " AND (tag = 'image' OR type LIKE '%png%' OR type LIKE '%tiff%' OR type LIKE '%jpeg%' OR type LIKE '%image%') AND LENGTH(data) > 5000000"
        case .largeRichText:
            whereClause += " AND (tag = 'rich' OR type LIKE '%rtf%' OR type LIKE '%html%') AND LENGTH(data) > 1000000"
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
    func deleteStorageItems(ids: [Int64]) async -> Int64 {
        guard let connection, !ids.isEmpty else { return 0 }
        var totalFreedBytes: Int64 = 0

        do {
            let idList = ids.map(String.init).joined(separator: ",")
            let sumSql = "SELECT COALESCE(SUM(LENGTH(data)), 0) FROM Clip WHERE id IN (\(idList))"
            if let sumStmt = try? connection.prepare(sumSql), let row = sumStmt.makeIterator().next() {
                totalFreedBytes = (row[0] as? Int64) ?? 0
            }

            let uidSql = "SELECT unique_id FROM Clip WHERE id IN (\(idList))"
            var uids: [String] = []
            if let uidStmt = try? connection.prepare(uidSql) {
                for row in uidStmt {
                    if let uid = row[0] as? String {
                        uids.append(uid)
                    }
                }
            }
            if !uids.isEmpty {
                SyncPendingDeletionsStore.shared.recordDeletions(uniqueIds: uids)
                Task { @MainActor in
                    DeferredOCRCoordinator.shared.remove(ids: ids)
                    SyncEngine.shared.markDirtyAndSchedule()
                }
            } else {
                Task { @MainActor in
                    DeferredOCRCoordinator.shared.remove(ids: ids)
                }
            }

            try connection.transaction {
                try connection.execute("DELETE FROM Clip WHERE id IN (\(idList))")
            }
            await refreshAppCache()
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

        Log.storage.info("数据库压缩整理(VACUUM)完成：释放物理碎片空间 \(beforeBytes - afterBytes) 字节 (从 \(beforeBytes) 压缩至 \(afterBytes))")
        return (beforeBytes, afterBytes)
    }

    // MARK: - 软配额老化与智能淘汰引擎

    /// 统计符合当前软配额老化策略的待淘汰条目数与预估释放字节数
    func getEvictionCandidates(policy: SoftQuotaAgingPolicy) -> (count: Int, bytes: Int64) {
        guard let connection else { return (0, 0) }
        let nowSec = Int64(Date().timeIntervalSince1970)
        let cutoffSec = nowSec - Int64(policy.days * 86400)

        let sql = """
            SELECT COUNT(*), COALESCE(SUM(LENGTH(data)), 0) FROM Clip
            WHERE (`group` IS NULL OR `group` = -1)
              AND (tag = 'image' OR lower(type) IN ('public.png', 'public.tiff', 'image/png', 'image/jpeg', 'image/tiff'))
              AND ((CASE WHEN timestamp > 10000000000 THEN timestamp / 1000 ELSE timestamp END) < \(cutoffSec))
        """

        do {
            let stmt = try connection.prepare(sql)
            if let row = stmt.makeIterator().next() {
                let count = Int((row[0] as? Int64) ?? 0)
                let bytes = (row[1] as? Int64) ?? 0
                return (count, bytes)
            }
        } catch {
            log.error("Failed to calculate eviction candidates: \(error)")
        }
        return (0, 0)
    }

    /// 执行智能淘汰瘦身：安全删除符合老化条件的未收藏旧图，并自动整理碎片
    func performAutoEviction(policy: SoftQuotaAgingPolicy, maxBytesToFree: Int64? = nil) async -> Int64 {
        guard let connection else { return 0 }
        let nowSec = Int64(Date().timeIntervalSince1970)
        let cutoffSec = nowSec - Int64(policy.days * 86400)

        let querySql = """
            SELECT id, LENGTH(data) FROM Clip
            WHERE (`group` IS NULL OR `group` = -1)
              AND (tag = 'image' OR lower(type) IN ('public.png', 'public.tiff', 'image/png', 'image/jpeg', 'image/tiff'))
              AND ((CASE WHEN timestamp > 10000000000 THEN timestamp / 1000 ELSE timestamp END) < \(cutoffSec))
            ORDER BY timestamp ASC
        """

        var idsToDelete: [Int64] = []
        var totalBytesFreed: Int64 = 0

        do {
            let stmt = try connection.prepare(querySql)
            for row in stmt {
                guard let id = row[0] as? Int64 else { continue }
                let bytes = (row[1] as? Int64) ?? 0
                idsToDelete.append(id)
                totalBytesFreed += bytes

                if let maxBytes = maxBytesToFree, totalBytesFreed >= maxBytes {
                    break
                }
            }

            if !idsToDelete.isEmpty {
                _ = await deleteStorageItems(ids: idsToDelete)
                _ = try? vacuumDatabase()
                Log.storage.info("自动淘汰完成：已清理 \(idsToDelete.count) 项未收藏旧图，释放 \(totalBytesFreed) 字节，已执行 VACUUM 回收磁盘")
            }
        } catch {
            log.error("Failed to perform auto eviction: \(error)")
        }

        return totalBytesFreed
    }
}
