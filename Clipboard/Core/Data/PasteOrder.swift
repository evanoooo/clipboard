import Foundation
import SQLite

/// 显示顺序独立于时间戳；只读取 ID 和序号，不加载剪贴板内容。
enum PasteOrder {
    nonisolated static func setup(on database: Connection) throws {
        try database.transaction(.immediate) {
            let columns = try database.prepare("PRAGMA table_info(Clip)")
                .compactMap { $0[1] as? String }
            if !columns.contains("sort_order") {
                try database.run("ALTER TABLE Clip ADD COLUMN sort_order INTEGER NOT NULL DEFAULT 0")
                try database.run("""
                    WITH ranks AS (
                        SELECT id, ROW_NUMBER() OVER (ORDER BY timestamp, id) AS rank
                        FROM Clip
                    )
                    UPDATE Clip SET sort_order = (SELECT rank * \(Col.orderStep) FROM ranks WHERE ranks.id = Clip.id)
                    """)
            }
            try database.run("CREATE INDEX IF NOT EXISTS idx_sort_order ON Clip(sort_order DESC, id DESC)")
            try database.run("CREATE INDEX IF NOT EXISTS idx_hidden_order ON Clip(hidden, sort_order DESC, id DESC)")
            try database.run("CREATE INDEX IF NOT EXISTS idx_group_hidden_order ON Clip(\"group\", hidden, sort_order DESC, id DESC)")
        }
    }

    nonisolated static func orderedEntries(on database: Connection) throws -> [(id: Int64, order: Int64)] {
        try database.prepare(Table("Clip").select(Col.id, Col.sortOrder).order(Col.sortOrder.desc, Col.id.desc))
            .map { ($0[Col.id], $0[Col.sortOrder]) }
    }

    /// 返回每个条目写入后的序号，供内存模型同步，避免撤销时用到过期位置。
    nonisolated static func promote(_ ids: [Int64], on database: Connection) throws -> [Int64: Int64] {
        var result: [Int64: Int64] = [:]
        try database.transaction(.immediate) {
            let table = Table("Clip")
            let stored = try database.scalar("SELECT COALESCE(MAX(sort_order), 0) FROM Clip")
            let base = (stored as? Int64) ?? 0
            for (offset, id) in ids.reversed().enumerated() {
                let nextOrder = base + Int64(offset + 1) * Col.orderStep
                try database.run(table.filter(Col.id == id).update(Col.sortOrder <- nextOrder))
                result[id] = nextOrder
            }
        }
        return result
    }

    /// 基于间隙的 O(1) 拖拽重排：仅查询锚点及相邻 1 条记录并计算中点序号；
    /// 仅当间隙耗尽时才执行一次全表步长重整（步长 65536）。
    /// 返回发生变更的条目新序号，供内存模型同步。
    nonisolated static func move(
        _ ids: [Int64],
        before: Int64?,
        after: Int64?,
        on database: Connection
    ) throws -> [(id: Int64, order: Int64)] {
        let moved = Set(ids)
        guard !ids.isEmpty, moved.count == ids.count else {
            throw PasteOrderError.missingItem
        }

        var result: [(id: Int64, order: Int64)] = []
        try database.transaction(.immediate) {
            let table = Table("Clip")
            // 校验所有待移动 ID 存在
            let existingCount = try database.scalar(
                table.filter(ids.contains(Col.id)).count
            )
            guard existingCount == ids.count else {
                throw PasteOrderError.missingItem
            }

            if let bounds = try resolveBounds(
                moved: moved,
                count: ids.count,
                before: before,
                after: after,
                table: table,
                on: database
            ) {
                let gap = bounds.upper - bounds.lower
                if gap >= Int64(ids.count + 1) {
                    for (idx, id) in ids.enumerated() {
                        let newOrder = bounds.upper - (gap * Int64(idx + 1)) / Int64(ids.count + 1)
                        try database.run(table.filter(Col.id == id).update(Col.sortOrder <- newOrder))
                        result.append((id, newOrder))
                    }
                    return
                }
            }

            // 间隙耗尽或锚点不可用时回退全表重整并分配步长 65536 的新序号
            result = try rebalanceAndMove(ids, before: before, after: after, table: table, on: database)
        }
        return result
    }

    nonisolated private static func resolveBounds(
        moved: Set<Int64>,
        count: Int,
        before: Int64?,
        after: Int64?,
        table: Table,
        on database: Connection
    ) throws -> (lower: Int64, upper: Int64)? {
        let stepPad = Int64(count + 1) * Col.orderStep
        if let before {
            guard !moved.contains(before),
                  let anchorRow = try database.pluck(table.select(Col.sortOrder).filter(Col.id == before)) else {
                throw PasteOrderError.missingItem
            }
            let lower = anchorRow[Col.sortOrder]
            let aboveQuery = table
                .select(Col.sortOrder)
                .filter(!moved.contains(Col.id) && (Col.sortOrder > lower || (Col.sortOrder == lower && Col.id > before)))
                .order(Col.sortOrder.asc, Col.id.asc)
                .limit(1)
            let upper = (try database.pluck(aboveQuery))?[Col.sortOrder] ?? (lower + stepPad)
            return (lower: lower, upper: upper)
        }

        if let after {
            guard !moved.contains(after),
                  let anchorRow = try database.pluck(table.select(Col.sortOrder).filter(Col.id == after)) else {
                throw PasteOrderError.missingItem
            }
            let upper = anchorRow[Col.sortOrder]
            let belowQuery = table
                .select(Col.sortOrder)
                .filter(!moved.contains(Col.id) && (Col.sortOrder < upper || (Col.sortOrder == upper && Col.id < after)))
                .order(Col.sortOrder.desc, Col.id.desc)
                .limit(1)
            let lower = (try database.pluck(belowQuery))?[Col.sortOrder] ?? (upper - stepPad)
            return (lower: lower, upper: upper)
        }

        throw PasteOrderError.missingItem
    }

    nonisolated private static func rebalanceAndMove(
        _ ids: [Int64],
        before: Int64?,
        after: Int64?,
        table: Table,
        on database: Connection
    ) throws -> [(id: Int64, order: Int64)] {
        let rows = try Array(database.prepare(
            table.select(Col.id, Col.sortOrder).order(Col.sortOrder.desc, Col.id.desc)
        ))
        let previous = rows.map { $0[Col.id] }
        let moved = Set(ids)
        var reordered = previous.filter { !moved.contains($0) }
        let destination: Int
        if let before, let index = reordered.firstIndex(of: before) {
            destination = index
        } else if before == nil, let after, let index = reordered.firstIndex(of: after) {
            destination = index + 1
        } else {
            throw PasteOrderError.missingItem
        }
        reordered.insert(contentsOf: ids, at: destination)

        let total = Int64(reordered.count)
        var result: [(id: Int64, order: Int64)] = []
        result.reserveCapacity(reordered.count)
        for (index, id) in reordered.enumerated() {
            let newOrder = (total - Int64(index)) * Col.orderStep
            if rows[index][Col.id] != id || rows[index][Col.sortOrder] != newOrder {
                try database.run(table.filter(Col.id == id).update(Col.sortOrder <- newOrder))
            }
            result.append((id, newOrder))
        }
        return result
    }
}
