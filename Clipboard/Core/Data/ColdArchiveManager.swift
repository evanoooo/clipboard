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
import SQLite

actor ColdArchiveManager {
    static let shared = ColdArchiveManager()

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

    /// 统计冷库可见条数（用于总条数与无缝冷分页）
    nonisolated static func archiveCount() -> Int {
        guard archiveExists(),
              let db = try? Connection(archiveDatabasePath, readonly: true) else {
            return 0
        }
        db.busyTimeout = 1.0
        return (try? db.scalar("SELECT COUNT(*) FROM Clip WHERE hidden = 0") as? Int64).map(Int.init) ?? 0
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
            return batch.count
        } catch {
            log.error("冷热分层归档事务失败：\(error)")
            return 0
        }
    }
}
