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

    private init() {}

    /// 必须在写入侧建表/迁移完成后调用。
    func setup() -> Bool {
        guard connection == nil else { return true }

        if let database = open(readonly: true) {
            connection = database
            log.info("只读连接已就绪")
            return true
        }

        // 只读连接打不开时回退到独立读写连接：仍与写入侧隔离，不阻断启动。
        if let database = open(readonly: false) {
            connection = database
            log.warn("只读连接不可用，已回退为独立读写连接")
            return true
        }

        log.error("查询连接打开失败")
        return false
    }

    private func open(readonly: Bool) -> Connection? {
        do {
            let database = try Connection(Self.databasePath, readonly: readonly)
            database.busyTimeout = 5.0
            try database.execute("PRAGMA query_only=1")
            try? database.execute("PRAGMA mmap_size=1073741824")
            return database
        } catch {
            log.error("查询连接打开失败（readonly=\(readonly)）：\(error)")
            return nil
        }
    }

    private static var databasePath: String {
        PasteSQLManager.databasePath
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
                Col.id, Col.uniqueId, Col.type, Col.data, Col.timestamp,
                Col.appID, Col.searchText,
                Col.showData, Col.length, Col.group,
                Col.tag, Col.alias, Col.hidden, Col.sortOrder
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
            let rows = Array(result)
            let elapsed = started.duration(to: .now)
            let message = "[search.sql] rows=\(rows.count) limit=\(limit ?? -1) offset=\(offset ?? 0) "
                + "elapsed=\(elapsed.millisecondsText)"
            if elapsed.milliseconds >= 50 {
                log.warn(message)
            } else {
                log.debug(message)
            }
            return rows
        } catch {
            log.error("查询失败：\(error)")
            return []
        }
    }

    func getCount(filter: Expression<Bool>?) async -> Int {
        let started = ContinuousClock.now
        do {
            let total: Int
            if let filter {
                total = try connection?.scalar(table.filter(filter).count) ?? 0
            } else {
                total = try connection?.scalar(table.count) ?? 0
            }
            log.debug(
                "[search.count] total=\(total) filtered=\(filter != nil) "
                    + "elapsed=\(started.duration(to: .now).millisecondsText)"
            )
            return total
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
