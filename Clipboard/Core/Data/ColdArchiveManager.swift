//
//  ColdArchiveManager.swift
//  Clipboard
//
//  冷热数据分层归档引擎：
//  将超过 180 天且未收藏/未分组（group == -1）的历史记录平滑迁移至只读冷库 ClipArchive.sqlite3，
//  保持主热库轻量高速，同时通过 PasteReadStore 联合检索与点查回温保证冷数据 100% 可搜可用。
//

import Darwin
import Foundation
import os
import SQLite

actor ColdArchiveManager {
    static let shared = ColdArchiveManager()

    private nonisolated static let archiveCountLock = OSAllocatedUnfairLock<Int?>(initialState: nil)

    private var archiveTask: Task<Void, Never>?
    private var hasCompletedThisSession = false
    private let retentionDays: Int64 = 180
    private let batchSize = 150

    private init() {}

    nonisolated static var archiveDatabasePath: String {
        let hotURL = URL(fileURLWithPath: PasteSQLManager.databasePath)
        return hotURL.deletingLastPathComponent()
            .appending(path: "ClipArchive.sqlite3")
            .path
    }

    nonisolated static func archiveExists() -> Bool {
        FileManager.default.fileExists(atPath: archiveDatabasePath)
    }

    func scheduleIdleArchivingIfNeeded() {
        guard !hasCompletedThisSession, archiveTask == nil else { return }
        archiveTask = Task(priority: .background) { [weak self] in
            // 冷启动避让 30 秒，确保首屏与前台操作零竞争
            try? await Task.sleep(for: .seconds(30))
            guard !Task.isCancelled else { return }
            await self?.runArchiveLoop()
        }
    }

    func cancel() {
        archiveTask?.cancel()
        archiveTask = nil
    }

    private func runArchiveLoop() async {
        defer { archiveTask = nil }
        let cutoff = Int64(Date().timeIntervalSince1970) - retentionDays * 86_400
        var totalArchived = 0

        while !Task.isCancelled {
            if ProcessInfo.processInfo.isLowPowerModeEnabled {
                try? await Task.sleep(for: .seconds(30))
                continue
            }

            let moved = await PasteSQLManager.manager.archiveColdBatch(
                cutoffTimestamp: cutoff,
                limit: batchSize
            )
            if moved > 0 {
                totalArchived += moved
                await PasteReadStore.shared.reopenArchive()
                malloc_zone_pressure_relief(malloc_default_zone(), 0)
                try? await Task.sleep(for: .milliseconds(250))
            } else {
                hasCompletedThisSession = true
                if totalArchived > 0 {
                    Log.storage.info("冷热分层归档完成：共将 \(totalArchived) 条 180 天前未收藏记录迁入 ClipArchive.sqlite3")
                    _ = try? await PasteSQLManager.manager.vacuumDatabase()
                }
                malloc_zone_pressure_relief(malloc_default_zone(), 0)
                return
            }
        }
    }

    /// 合并统计冷库中引用的外部 `.media/` 路径，防止孤儿 GC 误删冷数据图片
    nonisolated static func allReferencedMediaPaths() -> Set<String> {
        guard archiveExists(),
              let db = try? Connection(archiveDatabasePath, readonly: true) else {
            return []
        }
        db.busyTimeout = 2.0
        var paths = Set<String>()
        if let stmt = try? db.prepare("SELECT DISTINCT media_rel_path FROM Clip WHERE media_rel_path IS NOT NULL") {
            for row in stmt {
                if let p = row[0] as? String, !p.isEmpty {
                    paths.insert(p)
                }
            }
        }
        return paths
    }

    nonisolated static func invalidateCountCache() {
        archiveCountLock.withLock { $0 = nil }
    }

    /// 统计冷库可见条数（带内存缓存，写操作时显式失效）
    nonisolated static func archiveCount() -> Int {
        if let cached = archiveCountLock.withLock({ $0 }) {
            return cached
        }
        guard archiveExists(),
              let db = try? Connection(archiveDatabasePath, readonly: true) else {
            archiveCountLock.withLock { $0 = 0 }
            return 0
        }
        db.busyTimeout = 1.0
        let count = (try? db.scalar("SELECT COUNT(*) FROM Clip WHERE hidden = 0") as? Int64).map(Int.init) ?? 0
        archiveCountLock.withLock { $0 = count }
        return count
    }

    /// 当用户重新复制冷库中的记录时，将其从冷库移除以完成“回温”至热库（先只读存在性检查，避免每次拷贝开启读写事务）
    nonisolated static func removeFromArchiveIfPresent(uniqueId: String) {
        guard !uniqueId.isEmpty, archiveExists(),
              let roDb = try? Connection(archiveDatabasePath, readonly: true) else {
            return
        }
        roDb.busyTimeout = 1.0
        let exists = (try? roDb.scalar("SELECT 1 FROM Clip WHERE unique_id = ? LIMIT 1", uniqueId)) != nil
        guard exists, let rwDb = try? Connection(archiveDatabasePath) else {
            return
        }
        rwDb.busyTimeout = 2.0
        _ = try? rwDb.run("DELETE FROM Clip WHERE unique_id = ?", uniqueId)
        invalidateCountCache()
    }

    /// 按 unique_id 批量删除冷库记录（绝不使用 id，避免热冷库自增主键碰撞）
    nonisolated static func deleteFromArchive(uniqueIds: [String]) {
        guard !uniqueIds.isEmpty, archiveExists(),
              let rwDb = try? Connection(archiveDatabasePath) else {
            return
        }
        rwDb.busyTimeout = 2.0
        do {
            try rwDb.transaction(.immediate) {
                let chunkSize = 500
                for start in stride(from: 0, to: uniqueIds.count, by: chunkSize) {
                    let end = Swift.min(start + chunkSize, uniqueIds.count)
                    let chunk = Array(uniqueIds[start..<end])
                    let placeholders = Array(repeating: "?", count: chunk.count).joined(separator: ",")
                    let bindings: [Binding?] = chunk.map { $0 }
                    try rwDb.run("DELETE FROM Clip WHERE unique_id IN (\(placeholders))", bindings)
                }
            }
            invalidateCountCache()
        } catch {
            Log.database.error("删除冷库指定条目失败：\(error)")
        }
    }

    /// 按表达式条件删除冷库记录（仅用于非 id 列过滤，返回被删条目的 unique_id 列表）
    nonisolated static func deleteFromArchive(filter: SQLite.Expression<Bool>) -> [String] {
        guard archiveExists(),
              let rwDb = try? Connection(archiveDatabasePath) else {
            return []
        }
        rwDb.busyTimeout = 2.0
        let filtered = Table("Clip").filter(filter)
        let uids = (try? rwDb.prepare(filtered.select(Col.uniqueId)).map { $0[Col.uniqueId] }) ?? []
        guard !uids.isEmpty else { return [] }
        do {
            try rwDb.run(filtered.delete())
            invalidateCountCache()
        } catch {
            Log.database.error("按条件删除冷库条目失败：\(error)")
        }
        return uids
    }

    /// 按过期截止时间戳清理冷库未分组历史记录
    nonisolated static func deleteExpiredFromArchive(before cutoff: Int64) {
        guard archiveExists(),
              let rwDb = try? Connection(archiveDatabasePath) else {
            return
        }
        rwDb.busyTimeout = 2.0
        do {
            try rwDb.run(
                "DELETE FROM Clip WHERE timestamp < ? AND (\"group\" IS NULL OR \"group\" = -1)",
                cutoff
            )
            invalidateCountCache()
        } catch {
            Log.database.error("清理冷库过期历史失败：\(error)")
        }
    }

    /// 清空冷库记录（与热库 `clearHistory` 语义保持一致）
    nonisolated static func clearArchive(includePinnedAndGrouped: Bool) {
        guard archiveExists(),
              let rwDb = try? Connection(archiveDatabasePath) else {
            return
        }
        rwDb.busyTimeout = 5.0
        do {
            try rwDb.transaction(.immediate) {
                if includePinnedAndGrouped {
                    try rwDb.run("DELETE FROM Clip")
                    try rwDb.run("DELETE FROM App")
                } else {
                    try rwDb.run("DELETE FROM Clip WHERE \"group\" IS NULL OR \"group\" = -1")
                    try rwDb.run("DELETE FROM App WHERE id NOT IN (SELECT app_id FROM Clip WHERE app_id IS NOT NULL)")
                }
            }
            invalidateCountCache()
        } catch {
            Log.database.error("清空冷库失败：\(error)")
        }
    }

    /// 统计冷库文件物理占用、可见条数与可回收空闲页字节数
    nonisolated static func archiveDiskFilesSummary() -> (
        mainBytes: Int64,
        walBytes: Int64,
        shmBytes: Int64,
        itemCount: Int,
        reclaimableBytes: Int64
    ) {
        guard archiveExists() else { return (0, 0, 0, 0, 0) }
        let fm = FileManager.default
        let dbPath = archiveDatabasePath
        let mainBytes = (try? fm.attributesOfItem(atPath: dbPath)[.size] as? Int64) ?? 0
        let walBytes = (try? fm.attributesOfItem(atPath: dbPath + "-wal")[.size] as? Int64) ?? 0
        let shmBytes = (try? fm.attributesOfItem(atPath: dbPath + "-shm")[.size] as? Int64) ?? 0

        guard let roDb = try? Connection(dbPath, readonly: true) else {
            return (mainBytes, walBytes, shmBytes, 0, 0)
        }
        roDb.busyTimeout = 2.0
        let count = (try? roDb.scalar("SELECT COUNT(*) FROM Clip") as? Int64).map(Int.init) ?? 0
        let freelist = (try? roDb.scalar("PRAGMA freelist_count") as? Int64) ?? 0
        let pageSize = (try? roDb.scalar("PRAGMA page_size") as? Int64) ?? 4096
        return (mainBytes, walBytes, shmBytes, count, freelist * pageSize)
    }

    /// 统计冷库按数据类型的空间分布
    nonisolated static func archiveTypeProportions() -> [(rawType: String, count: Int, totalBytes: Int64)] {
        guard archiveExists(),
              let roDb = try? Connection(archiveDatabasePath, readonly: true) else {
            return []
        }
        roDb.busyTimeout = 2.0
        let sql = """
            SELECT type, COUNT(*) AS count, COALESCE(SUM(CASE WHEN media_size > 0 THEN media_size ELSE LENGTH(data) END), 0) AS total_bytes
            FROM Clip
            GROUP BY type
        """
        var result: [(String, Int, Int64)] = []
        if let stmt = try? roDb.prepare(sql) {
            for row in stmt {
                guard let rawType = row[0] as? String else { continue }
                let count = Int((row[1] as? Int64) ?? 0)
                let bytes = (row[2] as? Int64) ?? 0
                result.append((rawType, count, bytes))
            }
        }
        return result
    }

    /// 查询冷库占用空间最大的 Top N 条目（使用负数 ID 避免与热库行主键在 UI 选择集中碰撞）
    nonisolated static func archiveTopStorageItems(limit: Int, whereClause: String) -> [StorageItemSummary] {
        guard archiveExists(),
              let roDb = try? Connection(archiveDatabasePath, readonly: true) else {
            return []
        }
        roDb.busyTimeout = 2.0
        let sql = """
            SELECT id, unique_id, type, timestamp, app_id, tag, `group`,
                   (CASE WHEN media_size > 0 THEN media_size ELSE LENGTH(data) END) AS byte_size,
                   SUBSTR(search_text, 1, 100)
            FROM Clip
            \(whereClause)
            ORDER BY byte_size DESC
            LIMIT \(limit)
        """
        var items: [StorageItemSummary] = []
        let appNames = Dictionary(
            uniqueKeysWithValues: ((try? SourceAppSQL.readAll(on: roDb)) ?? []).map { ($0.id, $0.name) }
        )
        if let stmt = try? roDb.prepare(sql) {
            for row in stmt {
                guard let rawId = row[0] as? Int64 else { continue }
                let uniqueId = (row[1] as? String) ?? ""
                let type = (row[2] as? String) ?? "string"
                let timestamp = (row[3] as? Int64) ?? 0
                let appId = (row[4] as? Int64) ?? 0
                let tag = row[5] as? String
                let group = Int((row[6] as? Int64) ?? -1)
                let byteSize = (row[7] as? Int64) ?? 0
                let summary = (row[8] as? String) ?? ""

                items.append(StorageItemSummary(
                    id: -rawId,
                    uniqueId: uniqueId,
                    type: type,
                    timestamp: timestamp,
                    appID: appId,
                    appName: appNames[appId],
                    tag: tag,
                    group: group,
                    byteSize: byteSize,
                    summary: summary.trimmingCharacters(in: .whitespacesAndNewlines)
                ))
            }
        }
        return items
    }

    /// 统计冷库中符合软配额老化条件的待淘汰条数与字节数
    nonisolated static func archiveEvictionCandidates(cutoffSec: Int64) -> (count: Int, bytes: Int64) {
        guard archiveExists(),
              let roDb = try? Connection(archiveDatabasePath, readonly: true) else {
            return (0, 0)
        }
        roDb.busyTimeout = 2.0
        let sql = """
            SELECT COUNT(*), COALESCE(SUM(CASE WHEN media_size > 0 THEN media_size ELSE LENGTH(data) END), 0)
            FROM Clip
            WHERE (`group` IS NULL OR `group` = -1)
              AND (tag = 'image' OR lower(type) IN ('public.png', 'public.tiff', 'image/png', 'image/jpeg', 'image/tiff'))
              AND ((CASE WHEN timestamp > 10000000000 THEN timestamp / 1000 ELSE timestamp END) < \(cutoffSec))
        """
        if let stmt = try? roDb.prepare(sql), let row = stmt.makeIterator().next() {
            let count = Int((row[0] as? Int64) ?? 0)
            let bytes = (row[1] as? Int64) ?? 0
            return (count, bytes)
        }
        return (0, 0)
    }

    /// 按时间从旧到新列出冷库待淘汰记录，用于混合淘汰与精确配额释放
    nonisolated static func fetchArchiveEvictionItems(
        cutoffSec: Int64
    ) -> [(uniqueId: String, byteSize: Int64, timestamp: Int64)] {
        guard archiveExists(),
              let roDb = try? Connection(archiveDatabasePath, readonly: true) else {
            return []
        }
        roDb.busyTimeout = 2.0
        let sql = """
            SELECT unique_id,
                   (CASE WHEN media_size > 0 THEN media_size ELSE LENGTH(data) END),
                   (CASE WHEN timestamp > 10000000000 THEN timestamp / 1000 ELSE timestamp END) AS ts_sec
            FROM Clip
            WHERE (`group` IS NULL OR `group` = -1)
              AND (tag = 'image' OR lower(type) IN ('public.png', 'public.tiff', 'image/png', 'image/jpeg', 'image/tiff'))
              AND ((CASE WHEN timestamp > 10000000000 THEN timestamp / 1000 ELSE timestamp END) < \(cutoffSec))
            ORDER BY ts_sec ASC
        """
        var items: [(String, Int64, Int64)] = []
        if let stmt = try? roDb.prepare(sql) {
            for row in stmt {
                guard let uid = row[0] as? String, !uid.isEmpty else { continue }
                let bytes = (row[1] as? Int64) ?? 0
                let ts = (row[2] as? Int64) ?? 0
                items.append((uid, bytes, ts))
            }
        }
        return items
    }

    /// 按 unique_id 删除冷库存储条目并返回释放字节数
    nonisolated static func deleteStorageItemsFromArchive(uniqueIds: [String]) -> Int64 {
        guard !uniqueIds.isEmpty, archiveExists(),
              let rwDb = try? Connection(archiveDatabasePath) else {
            return 0
        }
        rwDb.busyTimeout = 2.0
        var freedBytes: Int64 = 0
        do {
            for start in stride(from: 0, to: uniqueIds.count, by: 500) {
                let end = Swift.min(start + 500, uniqueIds.count)
                let chunk = Array(uniqueIds[start..<end])
                let placeholders = Array(repeating: "?", count: chunk.count).joined(separator: ",")
                let bindings: [Binding?] = chunk.map { $0 }
                let sumSql = """
                    SELECT COALESCE(SUM(CASE WHEN media_size > 0 THEN media_size ELSE LENGTH(data) END), 0)
                    FROM Clip WHERE unique_id IN (\(placeholders))
                """
                if let stmt = try? rwDb.prepare(sumSql, bindings),
                   let row = stmt.makeIterator().next() {
                    freedBytes += (row[0] as? Int64) ?? 0
                }
                try rwDb.transaction(.immediate) {
                    try rwDb.run("DELETE FROM Clip WHERE unique_id IN (\(placeholders))", bindings)
                }
            }
            invalidateCountCache()
        } catch {
            Log.storage.error("删除冷库大体积条目失败：\(error)")
        }
        return freedBytes
    }

    /// 整理并压缩冷归档库物理磁盘空间（需在维护挂起期间调用）
    nonisolated static func vacuumArchive() -> (beforeBytes: Int64, afterBytes: Int64) {
        guard archiveExists() else { return (0, 0) }
        let fm = FileManager.default
        let dbPath = archiveDatabasePath
        let walPath = dbPath + "-wal"
        let beforeBytes = ((try? fm.attributesOfItem(atPath: dbPath)[.size] as? Int64) ?? 0)
            + ((try? fm.attributesOfItem(atPath: walPath)[.size] as? Int64) ?? 0)
        guard let rwDb = try? Connection(dbPath) else { return (beforeBytes, beforeBytes) }
        rwDb.busyTimeout = 5.0
        try? rwDb.execute("PRAGMA wal_checkpoint(TRUNCATE)")
        try? rwDb.execute("VACUUM")
        try? rwDb.execute("PRAGMA wal_checkpoint(TRUNCATE)")
        let afterBytes = ((try? fm.attributesOfItem(atPath: dbPath)[.size] as? Int64) ?? 0)
            + ((try? fm.attributesOfItem(atPath: walPath)[.size] as? Int64) ?? 0)
        return (beforeBytes, afterBytes)
    }

    /// 从冷库按 unique_id 点查完整二进制数据（支持外置 `.media/` 与库内 BLOB）
    nonisolated static func loadData(uniqueId: String) -> Data? {
        guard !uniqueId.isEmpty,
              archiveExists(),
              let db = try? Connection(archiveDatabasePath, readonly: true) else {
            return nil
        }
        db.busyTimeout = 1.0
        guard let row = try? db.prepare(
            "SELECT data, media_rel_path FROM Clip WHERE unique_id = ? LIMIT 1",
            uniqueId
        ).makeIterator().next() else {
            return nil
        }
        if let relPath = row[1] as? String, !relPath.isEmpty,
           let external = MediaBlobStore.shared.readBlob(relPath: relPath) {
            return external
        }
        if let blob = row[0] as? Blob {
            return Data(blob.bytes)
        }
        return nil
    }

    /// 从冷库按 unique_id 点查外置 `.media/` 文件 URL
    nonisolated static func loadMediaURL(uniqueId: String) -> URL? {
        guard !uniqueId.isEmpty,
              archiveExists(),
              let db = try? Connection(archiveDatabasePath, readonly: true) else {
            return nil
        }
        db.busyTimeout = 1.0
        guard let row = try? db.prepare(
            "SELECT media_rel_path FROM Clip WHERE unique_id = ? LIMIT 1",
            uniqueId
        ).makeIterator().next(),
              let relPath = row[0] as? String,
              !relPath.isEmpty else {
            return nil
        }
        return MediaBlobStore.shared.blobURL(for: relPath)
    }

    /// 从冷库按 unique_id 点查轻量 showData 缩略数据
    nonisolated static func loadShowData(uniqueId: String) -> Data? {
        guard !uniqueId.isEmpty,
              archiveExists(),
              let db = try? Connection(archiveDatabasePath, readonly: true) else {
            return nil
        }
        db.busyTimeout = 1.0
        guard let row = try? db.prepare(
            "SELECT show_data FROM Clip WHERE unique_id = ? LIMIT 1",
            uniqueId
        ).makeIterator().next(),
              let blob = row[0] as? Blob else {
            return nil
        }
        return Data(blob.bytes)
    }
}

extension PasteSQLManager {
    /// 将一批超过截止时间且未收藏/未隐藏的历史记录原子搬迁至冷库 `ClipArchive.sqlite3`（不触发同步待删除队列）
    func archiveColdBatch(cutoffTimestamp: Int64, limit: Int) -> Int {
        guard let hotConn = connection else { return 0 }

        let selectSQL = """
            SELECT id, unique_id, type, data, show_data, timestamp, app_id,
                   search_text, length, "group", tag, alias, alias_search, hidden,
                   sort_order, media_rel_path, media_size
            FROM Clip
            WHERE hidden = 0
              AND ("group" IS NULL OR "group" = -1)
              AND (CASE WHEN timestamp > 10000000000 THEN timestamp / 1000 ELSE timestamp END) < ?
            ORDER BY id ASC
            LIMIT ?
        """

        struct ColdRow {
            let id: Int64
            let uniqueId: String
            let type: String
            let data: Blob
            let showData: Blob?
            let timestamp: Int64
            let appID: Int64
            let searchText: String
            let length: Int64
            let group: Int64
            let tag: String?
            let alias: String?
            let aliasSearch: String?
            let hidden: Int64
            let sortOrder: Int64
            let mediaRelPath: String?
            let mediaSize: Int64
        }

        var batch: [ColdRow] = []
        do {
            let stmt = try hotConn.prepare(selectSQL, cutoffTimestamp, limit)
            for row in stmt {
                guard let id = row[0] as? Int64,
                      let uniqueId = row[1] as? String,
                      let type = row[2] as? String,
                      let data = row[3] as? Blob,
                      let timestamp = row[5] as? Int64 else {
                    continue
                }
                batch.append(ColdRow(
                    id: id,
                    uniqueId: uniqueId,
                    type: type,
                    data: data,
                    showData: row[4] as? Blob,
                    timestamp: timestamp,
                    appID: (row[6] as? Int64) ?? 0,
                    searchText: (row[7] as? String) ?? "",
                    length: (row[8] as? Int64) ?? 0,
                    group: (row[9] as? Int64) ?? -1,
                    tag: row[10] as? String,
                    alias: row[11] as? String,
                    aliasSearch: row[12] as? String,
                    hidden: (row[13] as? Int64) ?? 0,
                    sortOrder: (row[14] as? Int64) ?? 0,
                    mediaRelPath: row[15] as? String,
                    mediaSize: (row[16] as? Int64) ?? 0
                ))
            }
        } catch {
            log.error("查询待归档冷数据失败：\(error)")
            return 0
        }

        guard !batch.isEmpty else { return 0 }

        do {
            let archiveConn = try Connection(ColdArchiveManager.archiveDatabasePath)
            archiveConn.busyTimeout = 5.0
            try archiveConn.execute("PRAGMA journal_mode=WAL; PRAGMA synchronous=NORMAL;")
            Self.createTable(on: archiveConn, table: Table("Clip"))
            Self.createIndexes(on: archiveConn)
            try SourceAppSQL.create(on: archiveConn)

            // 同步缺失的 App 元数据，保证冷库联查应用名与图标正常
            let appIDs = Set(batch.map(\.appID)).filter { $0 > 0 }
            if !appIDs.isEmpty, let allApps = try? SourceAppSQL.readAll(on: hotConn) {
                let neededApps = allApps.filter { appIDs.contains($0.id) }
                if !neededApps.isEmpty {
                    let appStmt = try archiveConn.prepare(
                        "INSERT OR IGNORE INTO App (id, bundle_id, app_name, app_path) VALUES (?, ?, ?, ?)"
                    )
                    for app in neededApps {
                        try appStmt.run(app.id, app.bundleID, app.name, app.path)
                    }
                }
            }

            // 1. 先原子写入冷库
            try archiveConn.transaction(.immediate) {
                let insertSQL = """
                    INSERT OR IGNORE INTO Clip (
                        unique_id, type, data, show_data, timestamp, app_id,
                        search_text, length, "group", tag, alias, alias_search, hidden,
                        sort_order, media_rel_path, media_size
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """
                let insertStmt = try archiveConn.prepare(insertSQL)
                for item in batch {
                    try insertStmt.run(
                        item.uniqueId, item.type, item.data, item.showData,
                        item.timestamp, item.appID, item.searchText, item.length,
                        item.group, item.tag, item.alias, item.aliasSearch,
                        item.hidden, item.sortOrder, item.mediaRelPath, item.mediaSize
                    )
                }
            }

            // 2. 冷库落盘确认后，再从热库移除（不记录 SyncPendingDeletionsStore，避免误删云端）
            let ids = batch.map(\.id)
            try hotConn.transaction(.immediate) {
                try hotConn.run(table.filter(ids.contains(Col.id)).delete())
            }
            ColdArchiveManager.invalidateCountCache()
            return batch.count
        } catch {
            log.error("冷热分层归档事务失败：\(error)")
            return 0
        }
    }
}
