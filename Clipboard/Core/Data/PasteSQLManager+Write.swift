import AppKit
import Foundation
import SQLite

/// 批量同步纯净数据负载（避免跨 Actor 访问 PasteboardModel）
struct SyncIngestionRecord: Sendable {
    let uniqueId: String
    let type: String
    let data: Data
    let showData: Data?
    let timestamp: Int64
    let appID: Int64
    let searchText: String
    let length: Int
    let group: Int
    let tag: String
    let hidden: Bool
    let alias: String
}

extension PasteSQLManager {
    func deleteExpiredHistory(before cutoff: Int64) async throws {
        guard let connection else { throw CocoaError(.fileWriteUnknown) }
        let query = table.filter(Col.timestamp < cutoff && Col.group == -1)
        try connection.run(query.delete())
        await refreshAppCache()
    }

    private func resolvedAppID(for item: PasteboardModel) async throws -> Int64 {
        if let id = await item.appID { return id }
        let (name, path, bundleID) = await (item.appName, item.appPath, item.sourceBundleID)
        return try resolveApp(name: name, path: path, bundleID: bundleID)
    }

    private func sortOrder(of id: Int64) -> Int64 {
        guard let connection,
              let row = try? connection.pluck(
                  table.select(Col.sortOrder).filter(Col.id == id)
              )
        else { return 0 }
        return row[Col.sortOrder]
    }

    /// 批量同步入库（单事务提交，极致提升下载与恢复性能）
    func ingestSyncedBatch(_ records: [SyncIngestionRecord]) async {
        guard let connection, !records.isEmpty else { return }
        do {
            try connection.transaction {
                for r in records {
                    let existing = try? connection.pluck(
                        table.select(Col.id, Col.group, Col.appID).filter(Col.uniqueId == r.uniqueId)
                    )
                    if let existing {
                        let existingId = existing[Col.id]
                        let existingGroup = existing[Col.group]
                        var updates: [Setter] = [
                            Col.timestamp <- r.timestamp,
                            Col.hidden <- 0,
                            Col.sortOrder <- Col.nextSortOrder,
                            Col.data <- r.data,
                            Col.showData <- r.showData,
                            Col.searchText <- r.searchText,
                            Col.length <- r.length
                        ]
                        if r.group != -1, r.group != existingGroup {
                            updates.append(Col.group <- r.group)
                        }
                        updates += Self.aliasSetters(r.alias)
                        try connection.run(table.filter(Col.id == existingId).update(updates))
                    } else {
                        let insert = table.insert(
                            [
                                Col.uniqueId <- r.uniqueId,
                                Col.type <- r.type,
                                Col.data <- r.data,
                                Col.showData <- r.showData,
                                Col.timestamp <- r.timestamp,
                                Col.sortOrder <- Col.nextSortOrder,
                                Col.appID <- r.appID,
                                Col.searchText <- r.searchText,
                                Col.length <- r.length,
                                Col.group <- r.group,
                                Col.tag <- r.tag,
                                Col.hidden <- r.hidden ? 1 : 0,
                            ] + Self.aliasSetters(r.alias)
                        )
                        _ = try connection.run(insert)
                    }
                }
            }
            await refreshAppCache()
        } catch {
            log.error("批量同步入库失败：\(error)")
        }
    }

    /// 批量同步删除条目（单事务执行，避免多次写锁与触发器开销）
    func deleteByUniqueIds(_ uniqueIds: [String]) async {
        guard let connection, !uniqueIds.isEmpty else { return }
        do {
            try connection.transaction {
                let chunkSize = 500
                for start in stride(from: 0, to: uniqueIds.count, by: chunkSize) {
                    let end = Swift.min(start + chunkSize, uniqueIds.count)
                    let chunk = Array(uniqueIds[start..<end])
                    let query = table.filter(chunk.contains(Col.uniqueId))
                    _ = try connection.run(query.delete())
                }
            }
            await refreshAppCache()
            log.info("批量同步删除本地条目成功，共 \(uniqueIds.count) 条")
        } catch {
            log.error("批量同步删除本地条目失败：\(error)")
        }
    }

    func insert(item: PasteboardModel, timestamp: Int64, group: Int = -1) async -> PasteInsertResult {
        let existing = await search(
            filter: Col.uniqueId == item.uniqueId,
            select: [Col.id, Col.group, Col.appID],
            order: [],
            limit: 1
        ).first

        if let row = existing,
           let existingId = try? row.get(Col.id) {
            let existingGroup = (try? row.get(Col.group)) ?? -1
            let query = table.filter(Col.id == existingId)
            do {
                var updates: [Setter] = [
                    Col.timestamp <- timestamp, Col.hidden <- 0, Col.sortOrder <- Col.nextSortOrder
                ]
                if group != -1, group != existingGroup {
                    updates.append(Col.group <- group)
                }
                try connection?.run(query.update(updates))
                Log.database.info("更新已有条目时间戳：id=\(existingId)")
            } catch {
                log.error("更新时间戳失败：\(error)")
            }
            let effectiveGroup = group != -1 ? group : existingGroup
            return PasteInsertResult(
                id: existingId,
                group: effectiveGroup,
                appID: try? row.get(Col.appID),
                sortOrder: sortOrder(of: existingId)
            )
        }

        guard let appID = try? await resolvedAppID(for: item) else { return .failed }
        let insert = await table.insert(
            [
                Col.uniqueId <- item.uniqueId,
                Col.type <- item.pasteboardType.rawValue,
                Col.data <- item.data,
                Col.showData <- item.showData,
                Col.timestamp <- timestamp,
                Col.sortOrder <- Col.nextSortOrder,
                Col.appID <- appID,
                Col.searchText <- item.searchText,
                Col.length <- item.length,
                Col.group <- item.group,
                Col.tag <- item.tag,
                Col.hidden <- item.hidden ? 1 : 0,
            ] + Self.aliasSetters(item.alias)
        )
        do {
            let rowId = try connection?.run(insert)
            let id = rowId ?? -1
            Log.database.info("新增条目入库成功：id=\(id), type=\(item.pasteboardType.rawValue)")
            return PasteInsertResult(
                id: id,
                group: nil,
                appID: appID,
                sortOrder: sortOrder(of: id)
            )
        } catch {
            log.error("插入失败：\(error)")
        }
        return .failed
    }

    func delete(filter: Expression<Bool>) async {
        let query = table.filter(filter)
        do {
            let uids = (try? connection?.prepare(query.select(Col.uniqueId)).map { $0[Col.uniqueId] }) ?? []
            if !uids.isEmpty {
                SyncPendingDeletionsStore.shared.recordDeletions(uniqueIds: uids)
                Task { @MainActor in
                    SyncEngine.shared.markDirtyAndSchedule()
                }
            }
            let count = try connection?.run(query.delete())
            await refreshAppCache(debounce: true)
            Log.database.info("删除条目成功，影响行数：\(count ?? 0)")
        } catch {
            log.error("删除失败：\(error)")
        }
    }

    func delete(id: Int64) async {
        let idFilter = table.filter(Col.id == id)
        do {
            if let uid = try? connection?.pluck(idFilter.select(Col.uniqueId))?[Col.uniqueId] {
                SyncPendingDeletionsStore.shared.recordDeletions(uniqueIds: [uid])
                Task { @MainActor in
                    SyncEngine.shared.markDirtyAndSchedule()
                }
            }
            try connection?.run(idFilter.delete())
            await refreshAppCache(debounce: true)
        } catch {
            log.error("删除失败：\(error)，id：\(id)")
        }
    }

    /// 撤销删除：快照带着删除前的 sort_order 与 hidden，写回后回到原来的位置与可见性。
    /// 同一事务内完成，任一条失败则整体回滚。
    func restore(_ snapshots: [ClipSnapshot]) async -> [Int64] {
        guard let connection, !snapshots.isEmpty else { return [] }

        var restored: [Int64] = []
        do {
            try connection.transaction(.immediate) {
                for snapshot in snapshots {
                    // 删后又复制了同样内容：保留现存行（包括它现在的顺序），只合并分组与别名。
                    // 这是删除后新产生的行，不能套用快照的 hidden，否则刚复制的内容会立刻从主列表消失。
                    if let existing = try connection.pluck(
                        table.select(Col.id).filter(Col.uniqueId == snapshot.uniqueId)
                    ) {
                        let existingId = existing[Col.id]
                        let setters: [Setter] = [
                            Col.group <- snapshot.group,
                            Col.hidden <- 0,
                        ] + Self.aliasSetters(snapshot.alias)
                        try connection.run(table.filter(Col.id == existingId).update(setters))
                        restored.append(existingId)
                        continue
                    }

                    var setters: [Setter] = [
                        Col.uniqueId <- snapshot.uniqueId,
                        Col.type <- snapshot.type,
                        Col.data <- snapshot.data,
                        Col.showData <- snapshot.showData,
                        Col.timestamp <- snapshot.timestamp,
                        Col.sortOrder <- snapshot.sortOrder,
                        Col.appID <- snapshot.appID ?? 0,
                        Col.searchText <- snapshot.searchText,
                        Col.length <- snapshot.length,
                        Col.group <- snapshot.group,
                        Col.tag <- snapshot.tag,
                        Col.hidden <- snapshot.hidden ? 1 : 0,
                    ] + Self.aliasSetters(snapshot.alias)

                    // 原 id 已被其他记录占用时不指定 id，交给 SQLite 重新分配。
                    let idTaken = try connection.pluck(
                        table.select(Col.id).filter(Col.id == snapshot.id)
                    ) != nil
                    if !idTaken {
                        setters.insert(Col.id <- snapshot.id, at: 0)
                    }

                    restored.append(try connection.run(table.insert(setters)))
                }
            }
            Log.database.info("撤销恢复条目成功：共恢复 \(restored.count) 条")
        } catch {
            log.error("恢复删除失败：\(error)")
            return []
        }

        await refreshAppCache()
        return restored
    }

    /// 清空历史记录：默认仅删除未分组的普通流水（group == -1），保护已收藏和已分组的资产；
    /// 若 includePinnedAndGrouped 为 true，则彻底全量清空。
    func clearHistory(includePinnedAndGrouped: Bool = false) throws -> Bool {
        guard let connection else { throw CocoaError(.fileWriteUnknown) }
        try connection.transaction(.immediate) {
            if includePinnedAndGrouped {
                try connection.run(table.delete())
                try connection.run("DELETE FROM App")
            } else {
                try connection.run(table.filter(Col.group == -1).delete())
                try connection.run("DELETE FROM App WHERE id NOT IN (SELECT app_id FROM Clip WHERE app_id IS NOT NULL)")
            }
        }
        if includePinnedAndGrouped {
            apps.removeAll()
            appIdentities.removeAll()
        } else {
            Task { await self.refreshAppCache() }
        }
        do {
            try connection.execute("VACUUM")
            let busy = try connection.scalar("PRAGMA wal_checkpoint(TRUNCATE)") as? Int64
            let backup = URL(filePath: Self.databasePath).deletingLastPathComponent()
                .appending(path: "Clip.before-app-migration.sqlite3")
            if FileManager.default.fileExists(atPath: backup.path) { try FileManager.default.removeItem(at: backup) }
            return busy == 0
        } catch {
            log.error("历史已清空，空间回收失败：\(error)")
            return false
        }
    }

    func update(id: Int64, item: PasteboardModel) async {
        guard let appID = try? await resolvedAppID(for: item) else { return }
        let query = table.filter(Col.id == id)
        let update = await query.update(
            [
                Col.uniqueId <- item.uniqueId,
                Col.type <- item.pasteboardType.rawValue,
                Col.data <- item.data,
                Col.showData <- item.showData,
                Col.timestamp <- item.timestamp,
                Col.appID <- appID,
                Col.searchText <- item.searchText,
                Col.length <- item.length,
                Col.group <- item.group,
                Col.tag <- item.tag,
                Col.hidden <- item.hidden ? 1 : 0,
            ] + Self.aliasSetters(item.alias)
        )
        do {
            let count = try connection?.run(update)
            await refreshAppCache()
            log.debug("修改成功，影响行数：\(String(describing: count))")
        } catch {
            log.error("修改失败：\(error)")
        }
    }

    @discardableResult
    func updateItemGroup(id: Int64, groupId: Int) async -> Bool {
        let query = table.filter(Col.id == id)
        let update = query.update(Col.group <- groupId)
        do {
            let count = try connection?.run(update)
            Log.database.info("更新条目分组成功，影响行数：\(count ?? 0)")
            return (count ?? 0) > 0
        } catch {
            log.error("更新项目分组失败：\(error)")
            return false
        }
    }

    @discardableResult
    func updateItemHidden(id: Int64, hidden: Bool) async -> Bool {
        let query = table.filter(Col.id == id)
        let update = query.update(Col.hidden <- hidden ? 1 : 0)
        do {
            let count = try connection?.run(update)
            log.debug("更新项目 hidden 成功，影响行数：\(String(describing: count))")
            return (count ?? 0) > 0
        } catch {
            log.error("更新项目 hidden 失败：\(error)")
            return false
        }
    }

    /// 只更新别名，不碰触内容、类型与分组。
    func updateItemAlias(id: Int64, alias: String) async -> Bool {
        guard let database = connection else { return false }
        do {
            let count = try database.run(
                table.filter(Col.id == id).update(Self.aliasSetters(alias))
            )
            return count > 0
        } catch {
            log.error("更新别名失败：\(error)，id：\(id)")
            return false
        }
    }

    /// 别名原文入库，归一化文本单独存一列供检索。
    nonisolated static func aliasSetters(_ alias: String) -> [Setter] {
        let trimmed = alias.trimmingCharacters(in: .whitespacesAndNewlines)
        let raw: String? = trimmed.isEmpty ? nil : trimmed
        let normalized: String? = raw.map(SearchTextNormalizer.normalize)
            .flatMap { $0.isEmpty ? nil : $0 }
        return [Col.alias <- raw, Col.aliasSearch <- normalized]
    }

    func updateItemTag(
        id: Int64,
        expectedTag: String,
        newTag: String
    ) async -> Bool {
        guard let database = connection else { return false }

        let query = table.filter(
            (Col.id == id) && (Col.tag == expectedTag)
        )
        do {
            let count = try database.run(query.update(Col.tag <- newTag))
            guard count > 0 else { return false }
            log.debug("修复项目 tag 成功：\(expectedTag) -> \(newTag)，id：\(id)")
            return true
        } catch {
            log.error("修复项目 tag 失败：\(error)，id：\(id)")
            return false
        }
    }

    func updateItemContent(
        id: Int64,
        content: PasteContent,
        searchText: String
    ) async -> Bool {
        guard let connection else { return false }
        let uniqueId = await PasteboardModel.generateUniqueId(
            for: content.type,
            data: content.data
        )
        let timestamp = Int64(Date().timeIntervalSince1970)

        do {
            guard let currentRow = try connection.pluck(
                table
                    .select(Col.group)
                    .filter(Col.id == id)
            ) else {
                log.error("更新文本内容失败：记录不存在，id：\(id)")
                return false
            }

            let duplicateRow = try connection.pluck(
                table
                    .select(Col.id, Col.group)
                    .filter(Col.uniqueId == uniqueId && Col.id != id)
            )
            let duplicateId = duplicateRow?[Col.id]
            let duplicateGroup = duplicateRow?[Col.group] ?? -1
            let effectiveGroup = currentRow[Col.group] == -1 ? duplicateGroup : currentRow[Col.group]

            try connection.run("BEGIN IMMEDIATE TRANSACTION")
            if let duplicateId {
                try connection.run(table.filter(Col.id == duplicateId).delete())
            }

            let setters = contentSetters(content, searchText: searchText, uniqueId: uniqueId, group: effectiveGroup)
            let update = table.filter(Col.id == id).update(setters + [Col.timestamp <- timestamp])
            let count = try connection.run(update)
            guard count == 1 else {
                throw NSError(
                    domain: "PasteSQLManager",
                    code: 1,
                    userInfo: [
                        NSLocalizedDescriptionKey:
                            "更新文本内容影响行数异常：\(count)"
                    ]
                )
            }
            try connection.run("COMMIT")
            await refreshAppCache(debounce: true)
            log.debug("更新文本内容成功：\(id)")
            return true
        } catch {
            _ = try? connection.run("ROLLBACK")
            log.error("更新文本内容失败：\(error)")
            return false
        }
    }
    private func contentSetters(
        _ content: PasteContent,
        searchText: String,
        uniqueId: String,
        group: Int
    ) -> [Setter] {
        [
            Col.uniqueId <- uniqueId,
            Col.type <- content.type.rawValue,
            Col.data <- content.data,
            Col.showData <- content.showData,
            Col.searchText <- searchText,
            Col.length <- content.length,
            Col.group <- group,
            Col.tag <- content.tag,
            Col.sortOrder <- Col.nextSortOrder
        ]
    }

}
