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
    nonisolated private static func openReadOnlyConnection() -> Connection? {
        guard let db = try? Connection(Self.databasePath, readonly: true) else {
            return nil
        }
        db.busyTimeout = 2.0
        return db
    }

    /// 统计 SQLite（含热库与冷归档库）及 `.media/` 物理磁盘占用与碎片状态（只读连接，不阻塞写 Actor）
    nonisolated func getStorageDiskUsage() -> StorageDiskUsage {
        let fm = FileManager.default
        let dbPath = Self.databasePath
        let walPath = dbPath + "-wal"
        let shmPath = dbPath + "-shm"

        let archiveSummary = ColdArchiveManager.archiveDiskFilesSummary()
        let mainDbBytes = ((try? fm.attributesOfItem(atPath: dbPath)[.size] as? Int64) ?? 0) + archiveSummary.mainBytes
        let walBytes = ((try? fm.attributesOfItem(atPath: walPath)[.size] as? Int64) ?? 0) + archiveSummary.walBytes
        let shmBytes = ((try? fm.attributesOfItem(atPath: shmPath)[.size] as? Int64) ?? 0) + archiveSummary.shmBytes
        let mediaBytes = MediaBlobStore.shared.totalMediaDiskBytes()
        let totalDiskBytes = mainDbBytes + walBytes + shmBytes + mediaBytes

        var reclaimableFreeBytes = archiveSummary.reclaimableBytes
        var totalItemCount = archiveSummary.itemCount

        guard let readConn = Self.openReadOnlyConnection() else {
            return StorageDiskUsage(
                mainDbBytes: mainDbBytes,
                walBytes: walBytes,
                shmBytes: shmBytes,
                totalDiskBytes: totalDiskBytes,
                reclaimableFreeBytes: reclaimableFreeBytes,
                totalItemCount: totalItemCount
            )
        }

        reclaimableFreeBytes += ((try? readConn.scalar("PRAGMA freelist_count") as? Int64) ?? 0)
            * ((try? readConn.scalar("PRAGMA page_size") as? Int64) ?? 4096)
        totalItemCount += (try? readConn.scalar(Table("Clip").count)) ?? 0

        return StorageDiskUsage(
            mainDbBytes: mainDbBytes,
            walBytes: walBytes,
            shmBytes: shmBytes,
            totalDiskBytes: totalDiskBytes,
            reclaimableFreeBytes: reclaimableFreeBytes,
            totalItemCount: totalItemCount
        )
    }

    /// 获取按数据类型的占用空间分布（合并热库与冷归档库，只读连接不阻塞写 Actor）
    nonisolated func getStorageTypeProportions() -> [StorageTypeProportion] {
        var bucketByType: [String: (count: Int, totalBytes: Int64)] = [:]

        if let readConn = Self.openReadOnlyConnection() {
            let sql = ClipStorageQueries.typeProportionsSQL
            do {
                let stmt = try readConn.prepare(sql)
                for row in stmt {
                    guard let rawType = row[0] as? String else { continue }
                    let count = Int((row[1] as? Int64) ?? 0)
                    let totalBytes = (row[2] as? Int64) ?? 0
                    let existing = bucketByType[rawType] ?? (0, 0)
                    bucketByType[rawType] = (existing.count + count, existing.totalBytes + totalBytes)
                }
            } catch {
                Log.storage.error("Failed to query storage type proportions: \(error)")
            }
        }

        for (rawType, count, bytes) in ColdArchiveManager.archiveTypeProportions() {
            let existing = bucketByType[rawType] ?? (0, 0)
            bucketByType[rawType] = (existing.count + count, existing.totalBytes + bytes)
        }

        return bucketByType.map { rawType, stats in
            let (displayName, color) = Self.metadataForType(rawType)
            return StorageTypeProportion(
                typeName: rawType,
                displayName: displayName,
                count: stats.count,
                totalBytes: stats.totalBytes,
                color: color
            )
        }
        .sorted { $0.totalBytes > $1.totalBytes }
    }

    nonisolated private static func metadataForType(_ typeStr: String) -> (displayName: String, color: NSColor) {
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

    /// 获取占用空间最大的 Top N 条目（只读连接，不阻塞写 Actor）
    nonisolated func getTopStorageItems(limit: Int = 100, filter: StoragePresetFilter = .all) -> [StorageItemSummary] {
        guard let readConn = Self.openReadOnlyConnection() else { return [] }
        var list: [StorageItemSummary] = []

        let nowSec = Int64(Date().timeIntervalSince1970)
        let whereClause = ClipStorageQueries.topStorageItemsWhereClause(for: filter, nowSec: nowSec)
        let sql = ClipStorageQueries.topStorageItemsSQL(whereClause: whereClause, limit: limit)

        do {
            let appNames = Dictionary(
                uniqueKeysWithValues: ((try? SourceAppSQL.readAll(on: readConn)) ?? []).map { ($0.id, $0.name) }
            )
            let stmt = try readConn.prepare(sql)
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
                let appName = appNames[appId]

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
            Log.storage.error("Failed to query top storage items: \(error)")
        }

        let archiveItems = ColdArchiveManager.archiveTopStorageItems(limit: limit, whereClause: whereClause)
        if archiveItems.isEmpty {
            return list
        }
        return Array((list + archiveItems).sorted { $0.byteSize > $1.byteSize }.prefix(limit))
    }

    /// 用户主动勾选批量删除选中的大体积条目（同时支持热库主键与冷归档库 unique_id）
    func deleteStorageItems(ids: [Int64], archiveUniqueIds: [String] = []) async -> Int64 {
        guard let connection, !ids.isEmpty || !archiveUniqueIds.isEmpty else { return 0 }
        var totalFreedBytes: Int64 = 0
        var allUids: [String] = []

        do {
            for chunkStart in stride(from: 0, to: ids.count, by: 500) {
                let chunk = Array(ids[chunkStart..<min(chunkStart + 500, ids.count)])
                let idList = chunk.map(String.init).joined(separator: ",")
                let sumSql = """
                    SELECT COALESCE(SUM(CASE WHEN media_size > 0 THEN media_size ELSE LENGTH(data) END), 0)
                    FROM Clip WHERE id IN (\(idList))
                    """
                if let sumStmt = try? connection.prepare(sumSql), let row = sumStmt.makeIterator().next() {
                    totalFreedBytes += (row[0] as? Int64) ?? 0
                }

                let uidSql = "SELECT unique_id FROM Clip WHERE id IN (\(idList))"
                if let uidStmt = try? connection.prepare(uidSql) {
                    for row in uidStmt {
                        if let uid = row[0] as? String {
                            allUids.append(uid)
                        }
                    }
                }

                try connection.transaction {
                    try connection.execute("DELETE FROM Clip WHERE id IN (\(idList))")
                }
            }

            if !archiveUniqueIds.isEmpty {
                totalFreedBytes += ColdArchiveManager.deleteStorageItemsFromArchive(uniqueIds: archiveUniqueIds)
                allUids.append(contentsOf: archiveUniqueIds)
            }

            if !allUids.isEmpty || !ids.isEmpty {
                ClipStoreEventBus.shared.publish(
                    .itemsDeleted(uniqueIds: allUids, hotIds: ids)
                )
            }

            _ = purgeOrphanMediaBlobs()
            await refreshAppCache()
        } catch {
            log.error("Failed to delete storage items: \(error)")
        }
        return totalFreedBytes
    }

    /// 压缩并整理数据库碎片（VACUUM），真正将磁盘空间释放归还给 macOS（覆盖热库与冷归档库）
    func vacuumDatabase() async throws -> (beforeBytes: Int64, afterBytes: Int64) {
        guard let connection else {
            return (0, 0)
        }
        let fm = FileManager.default
        let dbPath = Self.databasePath
        let walPath = dbPath + "-wal"

        let beforeBytes = ((try? fm.attributesOfItem(atPath: dbPath)[.size] as? Int64) ?? 0)
            + ((try? fm.attributesOfItem(atPath: walPath)[.size] as? Int64) ?? 0)

        var archiveBefore: Int64 = 0
        var archiveAfter: Int64 = 0

        // 维护挂起点查双通道与只读连接，彻底解除只读锁并确保 VACUUM 与 WAL 截断无阻碍执行
        await PasteReadStore.shared.closeForMaintenance()
        try PasteDataPointReader.withMaintenanceSuspension {
            // 1. 将 WAL 日志 checkpoint 归档入主库
            try? connection.execute("PRAGMA wal_checkpoint(TRUNCATE)")
            // 2. 执行全量 VACUUM 释放 Free Pages
            try connection.execute("VACUUM")
            // 3. 再次将 VACUUM 产生的日志刷入并截断
            try? connection.execute("PRAGMA wal_checkpoint(TRUNCATE)")
            let archiveResult = ColdArchiveManager.vacuumArchive()
            archiveBefore = archiveResult.beforeBytes
            archiveAfter = archiveResult.afterBytes
        }

        let afterBytes = ((try? fm.attributesOfItem(atPath: dbPath)[.size] as? Int64) ?? 0)
            + ((try? fm.attributesOfItem(atPath: walPath)[.size] as? Int64) ?? 0)
        let totalBefore = beforeBytes + archiveBefore
        let totalAfter = afterBytes + archiveAfter

        await PasteReadStore.shared.reopen()
        Log.storage.info("数据库压缩整理(VACUUM)完成：释放物理碎片空间 \(totalBefore - totalAfter) 字节 (从 \(totalBefore) 压缩至 \(totalAfter))")
        return (totalBefore, totalAfter)
    }

    // MARK: - 软配额老化与智能淘汰引擎

    /// 统计符合当前软配额老化策略的待淘汰条目数与预估释放字节数（合并热库与冷归档库）
    nonisolated func getEvictionCandidates(policy: SoftQuotaAgingPolicy) -> (count: Int, bytes: Int64) {
        let nowSec = Int64(Date().timeIntervalSince1970)
        let cutoffSec = nowSec - Int64(policy.days * 86400)
        let archiveStats = ColdArchiveManager.archiveEvictionCandidates(cutoffSec: cutoffSec)

        guard let readConn = Self.openReadOnlyConnection() else {
            return archiveStats
        }

        let sql = ClipStorageQueries.evictionCandidatesCountSQL(cutoffSec: cutoffSec)

        do {
            let stmt = try readConn.prepare(sql)
            if let row = stmt.makeIterator().next() {
                let count = Int((row[0] as? Int64) ?? 0)
                let bytes = (row[1] as? Int64) ?? 0
                return (count + archiveStats.count, bytes + archiveStats.bytes)
            }
        } catch {
            Log.storage.error("Failed to calculate eviction candidates: \(error)")
        }
        return archiveStats
    }

    /// 执行智能淘汰瘦身：安全删除符合老化条件的未收藏旧图（覆盖热库与冷归档库），并自动整理碎片
    func performAutoEviction(policy: SoftQuotaAgingPolicy, maxBytesToFree: Int64? = nil) async -> Int64 {
        guard let connection else { return 0 }
        let nowSec = Int64(Date().timeIntervalSince1970)
        let cutoffSec = nowSec - Int64(policy.days * 86400)

        struct EvictionCandidate {
            let hotId: Int64?
            let archiveUniqueId: String?
            let bytes: Int64
            let timestampSec: Int64
        }

        let querySql = ClipStorageQueries.evictionItemsSQL(selectIdColumn: "id", cutoffSec: cutoffSec)

        var candidates: [EvictionCandidate] = []
        do {
            let stmt = try connection.prepare(querySql)
            for row in stmt {
                guard let id = row[0] as? Int64 else { continue }
                let bytes = (row[1] as? Int64) ?? 0
                let ts = (row[2] as? Int64) ?? 0
                candidates.append(EvictionCandidate(hotId: id, archiveUniqueId: nil, bytes: bytes, timestampSec: ts))
            }
        } catch {
            log.error("Failed to query hot eviction candidates: \(error)")
        }

        for archiveItem in ColdArchiveManager.fetchArchiveEvictionItems(cutoffSec: cutoffSec) {
            candidates.append(EvictionCandidate(
                hotId: nil,
                archiveUniqueId: archiveItem.uniqueId,
                bytes: archiveItem.byteSize,
                timestampSec: archiveItem.timestamp
            ))
        }

        candidates.sort { $0.timestampSec < $1.timestampSec }

        var hotIdsToDelete: [Int64] = []
        var archiveUidsToDelete: [String] = []
        var totalBytesFreed: Int64 = 0

        for candidate in candidates {
            if let hotId = candidate.hotId {
                hotIdsToDelete.append(hotId)
            } else if let uid = candidate.archiveUniqueId {
                archiveUidsToDelete.append(uid)
            }
            totalBytesFreed += candidate.bytes

            if let maxBytes = maxBytesToFree, totalBytesFreed >= maxBytes {
                break
            }
        }

        if !hotIdsToDelete.isEmpty || !archiveUidsToDelete.isEmpty {
            _ = await deleteStorageItems(ids: hotIdsToDelete, archiveUniqueIds: archiveUidsToDelete)
            _ = purgeOrphanMediaBlobs()
            _ = try? await vacuumDatabase()
            Log.storage.info("自动淘汰完成：已清理热库 \(hotIdsToDelete.count) 项与冷库 \(archiveUidsToDelete.count) 项未收藏旧图，释放 \(totalBytesFreed) 字节，已执行 VACUUM 回收磁盘")
        }

        return totalBytesFreed
    }

    /// 清理不再被数据库引用且超过 24 小时宽限期的外部 `.media/` 孤儿文件
    @discardableResult
    func purgeOrphanMediaBlobs() -> Int {
        guard let connection else { return 0 }
        do {
            let stmt = try connection.prepare("SELECT DISTINCT media_rel_path FROM Clip WHERE media_rel_path IS NOT NULL")
            var referenced = ColdArchiveManager.allReferencedMediaPaths()
            for row in stmt {
                if let path = row[0] as? String, !path.isEmpty {
                    referenced.insert(path)
                }
            }
            return MediaBlobStore.shared.purgeOrphanBlobs(referencedPaths: referenced)
        } catch {
            log.error("查询外部媒体引用失败：\(error)")
            return 0
        }
    }
}
