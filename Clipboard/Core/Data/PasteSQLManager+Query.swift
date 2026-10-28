import AppKit
import Foundation
import SQLite

extension PasteSQLManager {
    func hasExpiredHistory(before cutoff: Int64) throws -> Bool {
        guard let connection else { throw CocoaError(.fileReadUnknown) }
        let query = table.filter(Col.timestamp < cutoff && Col.group == -1)
        return try connection.scalar(query.exists)
    }

    func getTotalCount() async -> Int {
        do {
            return try connection?.scalar(table.count) ?? 0
        } catch {
            log.error("获取总数失败：\(error)")
            return 0
        }
    }

    func getHistoryStats() async -> (normalCount: Int, pinnedCount: Int) {
        do {
            guard let connection else { return (0, 0) }
            let normal = try connection.scalar(table.filter(Col.group == -1).count)
            let pinned = try connection.scalar(table.filter(Col.group != -1).count)
            return (normal, pinned)
        } catch {
            log.error("获取记录统计失败：\(error)")
            return (0, 0)
        }
    }

    /// 写连接上的查询：`insert` 用它按 `unique_id` 查重，需要读到自己刚写入的数据，
    /// 不能替换成 `PasteReadStore`。其余读路径请走只读通道。
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
            // 慢查询落盘，便于区分「SQL 本身慢」与「等待 actor/主线程」。
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

    func reorderItems(
        _ ids: [Int64],
        before: Int64?,
        after: Int64?
    ) -> [(id: Int64, order: Int64)]? {
        guard let database = connection else { return nil }
        do {
            return try PasteOrder.move(ids, before: before, after: after, on: database)
        } catch {
            log.error("保存卡片顺序失败：\(error)")
            return nil
        }
    }

    func orderedItemEntries() -> [(id: Int64, order: Int64)]? {
        guard let database = connection else { return nil }
        return try? PasteOrder.orderedEntries(on: database)
    }

    func promoteItems(_ ids: [Int64]) -> [Int64: Int64] {
        guard let database = connection else { return [:] }
        do {
            return try PasteOrder.promote(ids, on: database)
        } catch {
            log.error("置顶卡片失败：\(error)")
            return [:]
        }
    }

    func getDistinctAppInfo() -> [SourceApp] {
        guard let connection else { return [] }
        do {
            let ids = try connection.prepare("""
                SELECT app_id FROM Clip
                WHERE app_id IS NOT NULL
                GROUP BY app_id
                ORDER BY MAX(timestamp) DESC, app_id DESC
                """).compactMap { $0[0] as? Int64 }
            return ids.compactMap { apps[$0] }
        } catch {
            log.error("获取应用列表失败：\(error)")
            return []
        }
    }

    func getDistinctTags() async -> [String] {
        do {
            let query = table.select(distinct: Col.tag)
                .filter(Col.tag != nil)

            guard let result = try connection?.prepare(query) else { return [] }
            var tags: [String] = []
            for row in result {
                if let tag = try? row.get(Col.tag), !tag.isEmpty {
                    tags.append(tag)
                }
            }
            return tags.sorted()
        } catch {
            log.error("获取 tag 列表失败：\(error)")
            return []
        }
    }
}
