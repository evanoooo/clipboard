//
//  PasteReadStore.swift
//  Clipboard
//
//  只读查询通道：与写入共用 DB 文件但使用独立连接与 actor。
//  目的：复制大对象或触发 WAL 检查点时，搜索不再排队等待写入。
//

import AppKit
import Foundation
import SQLite

actor PasteReadStore {
    static let shared = PasteReadStore()

    private let table = Table("Clip")
    private var connection: Connection?
    private var archiveConnection: Connection?

    private init() {}

    /// 必须在写入侧建表/迁移完成后调用。
    func setup() -> Bool {
        guard connection == nil else { return true }

        if let database = open(path: Self.databasePath, readonly: true) {
            connection = database
            reopenArchive()
            log.info("只读连接已就绪")
            return true
        }

        // 只读连接打不开时回退到独立读写连接：仍与写入侧隔离，不阻断启动。
        if let database = open(path: Self.databasePath, readonly: false) {
            connection = database
            reopenArchive()
            log.warn("只读连接不可用，已回退为独立读写连接")
            return true
        }

        log.error("查询连接打开失败")
        return false
    }

    /// 在写连接执行 VACUUM / wal_checkpoint 前临时关闭只读连接以解除 WAL 占用
    func closeForMaintenance() {
        connection = nil
        archiveConnection = nil
    }

    /// 在写连接执行 VACUUM 重整数据库后重置只读连接句柄与 mmap 映射
    @discardableResult
    func reopen() -> Bool {
        connection = nil
        archiveConnection = nil
        return setup()
    }

    /// 刷新冷库只读连接（冷归档完成后按需挂载）
    func reopenArchive() {
        guard ColdArchiveManager.archiveExists() else {
            archiveConnection = nil
            return
        }
        archiveConnection = open(path: ColdArchiveManager.archiveDatabasePath, readonly: true)
    }

    private func open(path: String, readonly: Bool) -> Connection? {
        do {
            let database = try Connection(path, readonly: readonly)
            database.busyTimeout = 5.0
            try database.execute("PRAGMA query_only=1")
            let mmapBytes = Int64(PasteUserDefaults.sqliteMmapSizeMB) * 1024 * 1024
            try? database.execute("PRAGMA mmap_size=\(mmapBytes)")
            try? database.execute("PRAGMA temp_store=MEMORY")
            // 限制读连接页面缓存为 512KB，兼顾 50 条分页查询 B-Tree 命中与极致低内存
            try? database.execute("PRAGMA cache_size = -512")
            let mapped = (try? database.scalar("PRAGMA mmap_size")) as? Int64
            log.info("SQLite read connection mmap_size=\(mapped ?? 0)")
            return database
        } catch {
            log.error("查询连接打开失败（readonly=\(readonly)）：\(error)")
            return nil
        }
    }

    private static var databasePath: String {
        PasteSQLManager.databasePath
    }

    func setMmapSizeMB(_ mb: Int) {
        let bytes = Int64(mb) * 1024 * 1024
        try? connection?.execute("PRAGMA mmap_size=\(bytes)")
        let mapped = (try? connection?.scalar("PRAGMA mmap_size")) as? Int64
        log.info("Updated SQLite read connection mmap_size=\(mapped ?? 0)")
    }

    func search(
        filter: Expression<Bool>? = nil,
        select: [Expressible]? = nil,
        order: [Expressible]? = nil,
        limit: Int? = nil,
        offset: Int? = nil
    ) async -> [Row] {
        guard !Task.isCancelled else { return [] }

        let sel =
            select ?? [
                Col.id, Col.uniqueId, Col.type, Col.timestamp,
                Col.appID,
                Expression<String>(literal: "SUBSTR(search_text, 1, 2000) AS search_text"),
                Col.showData, Col.length, Col.group,
                Col.tag, Col.alias, Col.hidden, Col.sortOrder,
                Col.inlineData
            ]
        let ord = order ?? [Col.sortOrder.desc, Col.id.desc]

        var query = table.select(sel).order(ord)
        if let filter {
            query = query.filter(filter)
        }
        if let limit {
            query = query.limit(limit, offset: offset ?? 0)
        }

        do {
            let started = ContinuousClock.now
            guard let result = try connection?.prepare(query) else {
                return []
            }
            var rows = Array(result)

            // 联合检索/冷分页：仅当指定分页且热库结果不足一页时，无缝从只读冷库补齐
            if let limit, rows.count < limit, let archiveConnection {
                let remaining = limit - rows.count
                let archiveOffset: Int
                if !rows.isEmpty {
                    archiveOffset = 0
                } else if let offset, offset > 0 {
                    let hotTotal = countOn(connection, filter: filter, limit: nil)
                    archiveOffset = max(0, offset - hotTotal)
                } else {
                    archiveOffset = 0
                }

                var archiveQuery = table.select(sel).order(ord)
                if let filter {
                    archiveQuery = archiveQuery.filter(filter)
                }
                archiveQuery = archiveQuery.limit(remaining, offset: archiveOffset)
                if let archiveResult = try? archiveConnection.prepare(archiveQuery) {
                    rows.append(contentsOf: archiveResult)
                }
            }

            let elapsed = started.duration(to: .now)
            let message = "[search.sql] rows=\(rows.count) limit=\(limit ?? -1) offset=\(offset ?? 0) "
                + "elapsed=\(elapsed.millisecondsText)"
            if elapsed.milliseconds >= 50 {
                Log.database.warn(message)
            } else {
                Log.database.debug(message)
            }
            return rows
        } catch {
            log.error("查询失败：\(error)")
            return []
        }
    }

    /// 获取满足条件的数量；如果指定了 limit，则至多统计到 limit（如 501 用于 500+ 截断），仅扫描索引列避免大字段全表开销
    func getCount(filter: Expression<Bool>?, limit: Int? = nil) async -> Int {
        guard !Task.isCancelled else { return 0 }
        let started = ContinuousClock.now
        var total = countOn(connection, filter: filter, limit: limit)
        if let archiveConnection {
            if let limit {
                if total < limit {
                    total += countOn(archiveConnection, filter: filter, limit: limit - total)
                }
            } else {
                total += countOn(archiveConnection, filter: filter, limit: nil)
            }
        }
        log.debug(
            "[search.count] total=\(total) filtered=\(filter != nil) limit=\(limit ?? -1) "
                + "elapsed=\(started.duration(to: .now).millisecondsText)"
        )
        return total
    }

    private func countOn(
        _ db: Connection?,
        filter: Expression<Bool>?,
        limit: Int?
    ) -> Int {
        guard let db else { return 0 }
        do {
            if let limit {
                var query = table.select(Col.id)
                if let filter {
                    query = query.filter(filter)
                }
                query = query.limit(limit)
                guard let result = try? db.prepare(query) else { return 0 }
                var count = 0
                for _ in result {
                    count += 1
                    if Task.isCancelled { return count }
                }
                return count
            } else if let filter {
                return try db.scalar(table.filter(filter).count)
            } else {
                return try db.scalar(table.count)
            }
        } catch {
            log.error("获取筛选数量失败：\(error)")
            return 0
        }
    }

    func getCountByGroup(groupId: Int) async -> Int {
        do {
            return try connection?.scalar(table.filter(Col.group == groupId).count) ?? 0
        } catch {
            log.error("获取分组统计失败：\(error)")
            return 0
        }
    }
}
