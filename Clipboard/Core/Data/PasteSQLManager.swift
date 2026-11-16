//
//  PasteSQLManager.swift
//  Clipboard
//
//  Created by crown on 2025/9/16.
//

import AppKit
import Foundation
import SQLite

// Col is defined in Clipboard/Shared/ClipboardSchema.swift (shared with clipmcp target)

actor PasteSQLManager: ClipboardRepositoryProtocol {
    static let manager = PasteSQLManager()

    nonisolated private static var databaseDirectory: URL {
        URL.applicationSupportDirectory.appending(path: Bundle.main.bundleIdentifier ?? "Clip")
    }

    nonisolated static var databasePath: String {
        databaseDirectory.appending(path: "Clip.sqlite3").path
    }

    var connection: Connection?

    let table: Table
    var apps: [Int64: SourceApp] = [:]
    var appIdentities: [String: Int64] = [:]
    var pendingRefreshTask: Task<Void, Never>?

    private init() {
        table = Table("Clip")
    }

    func setMmapSizeMB(_ mb: Int) {
        let bytes = Int64(mb) * 1024 * 1024
        try? connection?.execute("PRAGMA mmap_size=\(bytes)")
        let mapped = (try? connection?.scalar("PRAGMA mmap_size")) as? Int64
        log.info("Updated SQLite write connection mmap_size=\(mapped ?? 0)")
    }

    private func openDatabase() throws {
        guard connection == nil else { return }
        try FileManager.default.createDirectory(at: Self.databaseDirectory, withIntermediateDirectories: true)
        let database = try Connection(Self.databasePath)
        database.busyTimeout = 5.0
        try database.execute("PRAGMA journal_mode=WAL")
        // WAL 模式黄金搭档：在保证事务原子性与断电安全前提下，大幅减少 fsync 同步阻塞，提升写入性能
        try? database.execute("PRAGMA synchronous=NORMAL")
        // 临时表与复杂排序驻留内存，杜绝临时文件写盘 I/O 尖刺
        try? database.execute("PRAGMA temp_store=MEMORY")
        // 限制写连接页面缓存为 512KB，避免默认 2000 页（约 8MB）常驻占用物理内存
        try? database.execute("PRAGMA cache_size = -512")
        // 整库虚拟内存映射：零拷贝极速检索，上限按用户配置生效
        let mmapBytes = Int64(PasteUserDefaults.sqliteMmapSizeMB) * 1024 * 1024
        try? database.execute("PRAGMA mmap_size=\(mmapBytes)")
        let mapped = (try? database.scalar("PRAGMA mmap_size")) as? Int64
        log.info("SQLite write connection mmap_size=\(mapped ?? 0)")
        Self.createTable(on: database, table: table)
        connection = database
    }

    nonisolated static func createTable(on conn: Connection, table: Table) {
        let statement = table.create(ifNotExists: true, withoutRowid: false) { schema in
            schema.column(Col.id, primaryKey: true)
            schema.column(Col.uniqueId)
            schema.column(Col.type)
            schema.column(Col.data)
            schema.column(Col.showData)
            schema.column(Col.timestamp)
            schema.column(Col.appID)
            schema.column(Col.searchText)
            schema.column(Col.length)
            schema.column(Col.group, defaultValue: -1)
            schema.column(Col.tag)
            schema.column(Col.alias)
            schema.column(Col.aliasSearch)
            schema.column(Col.hidden, defaultValue: 0)
            schema.column(Col.mediaRelPath)
            schema.column(Col.mediaSize, defaultValue: 0)
        }
        do {
            try conn.run(statement)
            try migrateMediaColumnsIfNeeded(on: conn)
            try clearRedundantPlainTextShowDataIfNeeded(on: conn)
            try PasteOrder.setup(on: conn)
            try PasteAliasMigration.setup(on: conn)
            try PasteFTSMigration.setup(on: conn)
        } catch {
            log.error("Create Table Error: \(error)")
        }
    }

    nonisolated private static func migrateMediaColumnsIfNeeded(on conn: Connection) throws {
        let columns = try conn.prepare("PRAGMA table_info(Clip)")
            .compactMap { $0[1] as? String }
        if !columns.contains("media_rel_path") {
            try conn.run("ALTER TABLE Clip ADD COLUMN media_rel_path TEXT")
        }
        if !columns.contains("media_size") {
            try conn.run("ALTER TABLE Clip ADD COLUMN media_size INTEGER NOT NULL DEFAULT 0")
        }
    }

    /// 清理历史纯文本冗余的 `show_data`（列表已统一由原文或 search_text 切片）
    nonisolated private static func clearRedundantPlainTextShowDataIfNeeded(on conn: Connection) throws {
        let hasLegacy = try conn.scalar(
            "SELECT 1 FROM Clip WHERE type = 'public.utf8-plain-text' AND show_data IS NOT NULL LIMIT 1"
        ) != nil
        guard hasLegacy else { return }
        try conn.run("UPDATE Clip SET show_data = NULL WHERE type = 'public.utf8-plain-text' AND show_data IS NOT NULL")
    }

    nonisolated static func createIndexes(on conn: Connection) {
        let indexes = [
            (
                "idx_sort_order",
                "CREATE INDEX IF NOT EXISTS idx_sort_order ON Clip(sort_order DESC, id DESC)"
            ),
            (
                "idx_hidden_order",
                "CREATE INDEX IF NOT EXISTS idx_hidden_order ON Clip(hidden, sort_order DESC, id DESC)"
            ),
            (
                "idx_group_hidden_order",
                "CREATE INDEX IF NOT EXISTS idx_group_hidden_order ON Clip(\"group\", hidden, sort_order DESC, id DESC)"
            ),
            (
                "idx_tag_hidden_order",
                "CREATE INDEX IF NOT EXISTS idx_tag_hidden_order ON Clip(tag, hidden, sort_order DESC, id DESC)"
            ),
            (
                "idx_app_hidden_order",
                "CREATE INDEX IF NOT EXISTS idx_app_hidden_order ON Clip(app_id, hidden, sort_order DESC, id DESC)"
            ),
            (
                "uidx_unique_id",
                "CREATE UNIQUE INDEX IF NOT EXISTS uidx_unique_id ON Clip(unique_id)"
            ),
            (
                "idx_hidden_ts",
                "CREATE INDEX IF NOT EXISTS idx_hidden_ts ON Clip(hidden, timestamp DESC)"
            ),
            (
                "idx_hidden_ts_app",
                "CREATE INDEX IF NOT EXISTS idx_hidden_ts_app ON Clip(hidden, timestamp DESC, app_id)"
            ),
            (
                "idx_unpinned_ts",
                "CREATE INDEX IF NOT EXISTS idx_unpinned_ts ON Clip(timestamp) WHERE \"group\" = -1"
            )
        ]

        var failedIndexes: [String] = []
        for (name, statement) in indexes {
            do {
                try conn.run(statement)
            } catch {
                failedIndexes.append(name)
                log.warn("创建索引 \(name) 失败: \(error)")
            }
        }

        guard failedIndexes.isEmpty else { return }

        let obsoleteIndexes = [
            "idx_app_name",
            "idx_tag",
            "idx_ts",
            "idx_group",
            "idx_unique_id",
            "idx_group_order",
            "idx_app_hidden_ts",
            "idx_tag_hidden_ts",
            "idx_group_ts"
        ]
        for name in obsoleteIndexes {
            do {
                try conn.run("DROP INDEX IF EXISTS \(name)")
            } catch {
                log.warn("清理旧索引 \(name) 失败: \(error)")
            }
        }
        log.info("索引初始化成功")
    }

    func setup() async -> Bool {
        do {
            try openDatabase()
            guard let connection else { return false }
            try SourceAppSQL.create(on: connection)
            let backupURL = Self.databaseDirectory.appending(path: "Clip.before-app-migration.sqlite3")
            let started = ContinuousClock.now
            if try SourceAppMigration.run(on: connection, backupURL: backupURL) {
                log.info("应用信息迁移完成，耗时：\(started.duration(to: .now))")
            }
            try SourceAppSQL.reassignMissing(on: connection, fallback: .current)
            try loadApps()
        } catch {
            log.error("应用信息迁移失败，保留原数据库：\(error)")
            return false
        }
        await migrateUniqueIdIfNeeded()

        guard let connection else { return false }
        try? PasteFTSMigration.setup(on: connection)
        Self.createIndexes(on: connection)
        return true
    }
}
