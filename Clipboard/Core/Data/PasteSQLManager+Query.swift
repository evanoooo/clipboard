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
                SELECT a.id FROM App a
                WHERE EXISTS (SELECT 1 FROM Clip WHERE app_id = a.id)
                ORDER BY MAX(
                    COALESCE((SELECT MAX(timestamp) FROM Clip WHERE app_id = a.id AND hidden = 0), -1),
                    COALESCE((SELECT MAX(timestamp) FROM Clip WHERE app_id = a.id AND hidden = 1), -1)
                ) DESC, a.id DESC
                """).compactMap { $0[0] as? Int64 }
            return ids.compactMap { apps[$0] }
        } catch {
            log.error("获取应用列表失败：\(error)")
            return []
        }
    }

    func getDistinctTags() async -> [String] {
        do {
            var tags: Set<String> = []
            let query = table.select(distinct: Col.tag)
                .filter(Col.tag != nil)

            if let result = try connection?.prepare(query) {
                for row in result {
                    if let tag = try? row.get(Col.tag),
                       !tag.isEmpty {
                        tags.insert(tag)
                    }
                }
            }
            return Array(tags).sorted()
        } catch {
            log.error("获取 tag 列表失败：\(error)")
            return []
        }
    }

    func getCountByGroup(groupId: Int) async -> Int {
        do {
            let query = table.filter(Col.group == groupId)
            return try connection?.scalar(query.count) ?? 0
        } catch {
            log.error("获取分组统计失败：\(error)")
            return 0
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
}
