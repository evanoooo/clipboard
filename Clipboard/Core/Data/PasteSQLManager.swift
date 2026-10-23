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
        }
        do {
            try conn.run(statement)
            try PasteOrder.setup(on: conn)
            try PasteAliasMigration.setup(on: conn)
            try PasteFTSMigration.setup(on: conn)
        } catch {
            log.error("Create Table Error: \(error)")
        }
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
