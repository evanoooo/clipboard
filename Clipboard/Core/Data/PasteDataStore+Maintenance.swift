//
//  PasteDataStore+Maintenance.swift
//  Clipboard
//

import AppKit
import Combine
import SQLite

extension PasteDataStore {
    /// 置顶要等数据库写完再发布：内存里的 sortOrder 必须与库一致，否则撤销会用过期位置。
    func moveItemsToFirst(_ models: [PasteboardModel]) {
        guard !models.isEmpty else { return }

        let ids = models.compactMap(\.id)
        guard !ids.isEmpty else { return }

        enqueueMutation { [weak self, sqlManager] in
            let orders = await sqlManager.promoteItems(ids)
            guard let self else { return }

            for model in models {
                guard let id = model.id, let order = orders[id] else { continue }
                model.sortOrder = order
            }

            let movedIds = Set(ids)
            var list = dataList.value.filter { item in
                guard let id = item.id else { return true }
                return !movedIds.contains(id)
            }
            list.insert(contentsOf: models, at: 0)

            if list.count > pageSize {
                list = Array(list.prefix(pageSize))
            }
            updateData(with: list, changeType: .moveToFirst)
        }
    }

    func deleteItems(_ items: PasteboardModel...) {
        deleteItems(items)
    }

    /// - Parameter recordUndo: 多选删除由调用方汇总成一条记录时传 false。
    func deleteItems(_ items: [PasteboardModel], recordUndo: Bool = true) {
        let deletedIds = Set(items.compactMap(\.id))
        guard !deletedIds.isEmpty else { return }

        let uids = items.map(\.uniqueId)
        SyncPendingDeletionsStore.shared.recordDeletions(uniqueIds: uids)
        SyncEngine.shared.markDirtyAndSchedule()

        if recordUndo {
            let snapshots = items.compactMap { ClipSnapshot(model: $0) }
            ClipUndoStore.shared.push(.deleted(snapshots))
        }

        var list = dataList.value
        list.removeAll { item in
            guard let id = item.id else { return false }
            return deletedIds.contains(id)
        }

        let deficit = pageSize - list.count
        if deficit > 0, hasMoreData {
            deleteAndBackfill(
                deletedIds,
                deficit: deficit,
                currentCount: list.count
            )
        } else {
            updateData(with: list, changeType: .delete)
            deleteStoredItems(deletedIds)
        }
    }

    /// 撤销最近一次删除。未恢复的部分在 `failedAction` 中返回，并已回推栈以便重试。
    @discardableResult
    func undoLastDelete() async -> UndoOutcome {
        guard !isUndoing, let action = ClipUndoStore.shared.pop() else {
            return UndoOutcome(restoredIds: [], failedAction: nil)
        }

        isUndoing = true
        defer { isUndoing = false }

        // 先等删除/移组/隐藏/置顶落库，否则恢复后可能被排队的写操作再次覆盖。
        await awaitPendingMutations()
        let outcome = await applyUndo(action)

        if let failedAction = outcome.failedAction {
            ClipUndoStore.shared.push(failedAction)
        }
        if !outcome.restoredIds.isEmpty {
            await reloadAfterUndo(outcome.restoredIds)
        } else {
            NSSound.beep()
        }
        return outcome
    }

    private func applyUndo(_ action: ClipUndoAction) async -> UndoOutcome {
        switch action {
        case let .batch(actions):
            var restored: [Int64] = []
            var failed: [ClipUndoAction] = []
            for sub in actions.reversed() {
                let outcome = await applyUndo(sub)
                restored += outcome.restoredIds
                if let failedAction = outcome.failedAction {
                    failed.append(failedAction)
                }
            }
            return UndoOutcome(
                restoredIds: restored,
                failedAction: failed.isEmpty ? nil : .batch(failed)
            )

        case let .deleted(snapshots):
            // 恢复在单个事务中执行：要么全部成功，要么全部回滚。
            let restored = await sqlManager.restore(snapshots)
            let restoredUids = snapshots.filter { restored.contains($0.id) }.map(\.uniqueId)
            SyncPendingDeletionsStore.shared.removeDeletions(uniqueIds: restoredUids)
            SyncEngine.shared.markDirtyAndSchedule()
            return UndoOutcome(
                restoredIds: restored,
                failedAction: restored.isEmpty ? action : nil
            )

        case let .ungrouped(ids, groupId):
            var restored: [Int64] = []
            var failed: [Int64] = []
            for id in ids {
                if await sqlManager.updateItemGroup(id: id, groupId: groupId) {
                    restored.append(id)
                } else {
                    failed.append(id)
                }
            }
            return UndoOutcome(
                restoredIds: restored,
                failedAction: failed.isEmpty ? nil : .ungrouped(ids: failed, groupId: groupId)
            )

        case let .hidden(ids):
            var restored: [Int64] = []
            var failed: [Int64] = []
            for id in ids {
                if await sqlManager.updateItemHidden(id: id, hidden: false) {
                    restored.append(id)
                } else {
                    failed.append(id)
                }
            }
            return UndoOutcome(
                restoredIds: restored,
                failedAction: failed.isEmpty ? nil : .hidden(ids: failed)
            )
        }
    }

    /// 恢复后按当前视图重查，保持筛选/搜索状态不变，并定位到被恢复的条目。
    private func reloadAfterUndo(_ restoredIds: [Int64]) async {
        // 保持撤销前的加载深度：被删的可能在第二页之后，只重查首页会让它“消失”。
        let loaded = max(dataList.value.count, pageSize)
        resetPagination()

        guard isInFilterMode, let filter = currentFilter else {
            totalCount = await sqlManager.getTotalCount()
            await resetDefaultList(focusIds: restoredIds, limit: loaded)
            return
        }

        let rows = await PasteReadStore.shared.search(filter: filter, limit: loaded)
        let list = await mapRows(rows)
        totalCount = await sqlManager.getTotalCount()
        let scanned = await PasteReadStore.shared.getCount(filter: filter, limit: Self.countScanLimit)
        updateFilteredCount(scanned: scanned)
        setHasMoreData(isFilteredCountCapped || rows.count == loaded)
        requestFocus(at: focusIndex(in: list, ids: restoredIds))
        updateData(with: list, changeType: .searchFilter)
    }

    private func deleteAndBackfill(
        _ deletedIds: Set<Int64>,
        deficit: Int,
        currentCount: Int
    ) {
        let inFilter = isInFilterMode
        let activeFilter = currentFilter

        enqueueMutation { [weak self, sqlManager] in
            guard let self else { return }

            await sqlManager.delete(filter: deletedIds.contains(Col.id))
            let count = await sqlManager.getTotalCount()
            let filter = inFilter ? activeFilter : nil
            let rows = await PasteReadStore.shared.search(
                filter: filter ?? (Col.hidden == 0),
                limit: deficit,
                offset: currentCount
            )
            let backfillItems = await mapRows(rows)
            let scanned: Int? =
                if inFilter, let activeFilter {
                    await PasteReadStore.shared.getCount(filter: activeFilter, limit: Self.countScanLimit)
                } else {
                    nil
                }

            await MainActor.run { [weak self] in
                guard let self else { return }
                totalCount = count
                if let scanned {
                    updateFilteredCount(scanned: scanned)
                } else {
                    filterState.filteredCount = count
                    filterState.isCountCapped = false
                    countUpdated.send()
                }

                var finalList = dataList.value
                finalList.removeAll { item in
                    guard let id = item.id else { return false }
                    return deletedIds.contains(id)
                }

                let existingIds = Set(finalList.compactMap(\.id))
                let uniqueBackfill = backfillItems.filter { item in
                    guard let id = item.id else { return true }
                    return !existingIds.contains(id)
                }
                finalList += uniqueBackfill

                setHasMoreData(finalList.count >= pageSize)
                updateData(with: finalList, changeType: .delete)
            }
        }
    }

    private func deleteStoredItems(_ deletedIds: Set<Int64>) {
        let inFilter = isInFilterMode
        let activeFilter = currentFilter

        enqueueMutation { [weak self, sqlManager] in
            await sqlManager.delete(filter: deletedIds.contains(Col.id))
            let count = await sqlManager.getTotalCount()
            let scanned: Int? =
                if inFilter, let activeFilter {
                    await PasteReadStore.shared.getCount(filter: activeFilter, limit: Self.countScanLimit)
                } else {
                    nil
                }

            await MainActor.run { [weak self] in
                guard let self else { return }
                totalCount = count
                if let scanned {
                    updateFilteredCount(scanned: scanned)
                } else {
                    filterState.filteredCount = count
                    filterState.isCountCapped = false
                    countUpdated.send()
                }
            }
        }
    }

    func deleteItems(filter: Expression<Bool>) {
        let inFilter = isInFilterMode
        let activeFilter = currentFilter

        enqueueMutation { [weak self, sqlManager] in
            await sqlManager.delete(filter: filter)
            let count = await sqlManager.getTotalCount()

            let scanned: Int? =
                if inFilter, let activeFilter {
                    await PasteReadStore.shared.getCount(filter: activeFilter, limit: Self.countScanLimit)
                } else {
                    nil
                }

            await MainActor.run { [weak self] in
                guard let self else { return }
                totalCount = count
                if let scanned {
                    updateFilteredCount(scanned: scanned)
                } else {
                    filterState.filteredCount = count
                    filterState.isCountCapped = false
                    countUpdated.send()
                }
            }
        }
    }

    func deleteItemsByGroup(_ groupId: Int) {
        deleteItems(filter: Col.group == groupId)
    }

    func remove(at index: Int) {
        var list = dataList.value
        list.remove(at: index)
        dataList.send(list)
    }

    func clearExpiredData() {
        clearDragTempDirectory()

        let lastDate = PasteUserDefaults.lastClearDate
        let dateStr = Date().formatted(date: .numeric, time: .omitted)
        if lastDate == dateStr {
            return
        }
        PasteUserDefaults.lastClearDate = dateStr

        let currentValue = PasteUserDefaults.historyTime
        let timeUnit = HistoryTimeUnit(rawValue: currentValue)
        clearData(for: timeUnit)
    }

    private func clearDragTempDirectory() {
        Task.detached(priority: .background) {
            let tempURL = FileManager.default.temporaryDirectory.appending(path: "ClipboardDrag")
            let fileManager = FileManager.default
            guard let enumerator = fileManager.enumerator(
                at: tempURL,
                includingPropertiesForKeys: [.contentModificationDateKey],
                options: [.skipsHiddenFiles]
            ) else { return }

            let oneDayAgo = Date().addingTimeInterval(-86400)
            while let fileURL = enumerator.nextObject() as? URL {
                guard let resourceValues = try? fileURL.resourceValues(forKeys: [.contentModificationDateKey]),
                      let modDate = resourceValues.contentModificationDate,
                      modDate < oneDayAgo
                else { continue }
                try? fileManager.removeItem(at: fileURL)
            }
        }
    }

    func clearData(for timeUnit: HistoryTimeUnit) {
        guard let cutoff = timeUnit.cutoffTimestamp() else { return }
        log.info("清理过期数据，截止时间戳：\(cutoff)")
        let list = dataList.value.filter { $0.group != -1 || $0.timestamp >= cutoff }
        updateData(with: list)
        deleteItems(filter: Col.timestamp < cutoff && Col.group == -1)
    }

    /// 确认并清理超出新期限的记录；设置仅由调用方在成功后保存
    func confirmHistoryLimit(_ timeUnit: HistoryTimeUnit) async -> Bool {
        guard let cutoff = timeUnit.cutoffTimestamp() else { return true }
        do {
            guard try await sqlManager.hasExpiredHistory(before: cutoff) else { return true }
            guard let window = SettingWindowController.shared.window, window.isVisible else { return false }
            let alert = NSAlert.appAlert()
            alert.alertStyle = .warning
            alert.messageText = String(localized: .generalHistoryLimitConfirmTitle)
            alert.informativeText = String(localized: .generalHistoryLimitConfirmMessage)
            alert.addButton(withTitle: String(localized: .commonCancel))
            let deleteButton = alert.addButton(withTitle: String(localized: .delete))
            deleteButton.hasDestructiveAction = true
            guard await alert.beginSheetModal(for: window) == .alertSecondButtonReturn else { return false }

            try await sqlManager.deleteExpiredHistory(before: cutoff)
            await reloadHistory()
            return true
        } catch {
            log.error("应用历史保留期限失败：\(error)")
            if let window = SettingWindowController.shared.window, window.isVisible {
                let alert = NSAlert.appAlert()
                alert.alertStyle = .warning
                alert.messageText = String(localized: .generalHistoryLimitFailed)
                alert.addButton(withTitle: String(localized: .commonConfirm))
                await alert.beginSheetModal(for: window)
            }
            return false
        }
    }

    func loadHistoryPage() async -> [PasteboardModel]? {
        while !Task.isCancelled {
            let revision = listRevision
            let filterVersion = filterRevision
            let filter = isInFilterMode ? currentFilter : nil
            let rows = await PasteReadStore.shared.search(filter: filter ?? (Col.hidden == 0), limit: pageSize)
            let list = await mapRows(rows)
            let count = await sqlManager.getTotalCount()
            let scanned = if let filter { await PasteReadStore.shared.getCount(filter: filter, limit: Self.countScanLimit) } else { count }
            guard !Task.isCancelled else { return nil }
            guard revision == listRevision, filterVersion == filterRevision else { continue }
            totalCount = count
            if filter != nil {
                updateFilteredCount(scanned: scanned)
            } else {
                filterState.filteredCount = count
                filterState.isCountCapped = false
                countUpdated.send()
            }
            setHasMoreData(isFilteredCountCapped || list.count < filteredCount)
            return list
        }
        return nil
    }

    func clearAllData() {
        guard !clearingHistory.value else { return }
        Task { @MainActor in
            let (normalCount, pinnedCount) = await sqlManager.getHistoryStats()
            let alert = NSAlert.appAlert()
            alert.alertStyle = .warning
            alert.messageText = String(localized: .clearHistoryAlertTitle)

            if pinnedCount > 0 {
                alert.informativeText = String(localized: .clearHistoryMessageWithPinned(normalCount, pinnedCount))
            } else {
                alert.informativeText = String(localized: .clearHistoryMessageNormalOnly(normalCount))
            }

            alert.addButton(withTitle: String(localized: .commonCancel))
            let deleteButton = alert.addButton(withTitle: String(localized: .clearHistoryButton))
            deleteButton.hasDestructiveAction = true

            var checkbox: NSButton?
            if pinnedCount > 0 {
                let cb = NSButton(checkboxWithTitle: String(localized: .clearHistoryIncludePinned), target: nil, action: nil)
                cb.state = .off
                cb.frame = NSRect(x: 0, y: 0, width: 340, height: 22)
                alert.accessoryView = cb
                checkbox = cb
            }

            let response: NSApplication.ModalResponse
            if let window = SettingWindowController.shared.window, window.isVisible {
                response = await alert.beginSheetModal(for: window)
            } else {
                response = alert.runModal()
            }

            guard response == .alertSecondButtonReturn else { return }

            let includePinned = checkbox?.state == .on
            clearingHistory.send(true)

            do {
                let reclaimed = try await sqlManager.clearHistory(includePinnedAndGrouped: includePinned)
                ClipUndoStore.shared.removeAll()
                if includePinned {
                    SourceAppCache.shared.replace([])
                    AppColorService.shared.clearColors()
                    CategoryChipStore.shared.clearUserCategories()
                    resetToDefault()
                } else {
                    await reloadHistory()
                }
                clearingHistory.send(false)
                if reclaimed {
                    showClearHistoryResult(String(localized: .clearHistorySuccess), style: .informational)
                } else {
                    showClearHistoryResult(String(localized: .clearHistorySpaceFailed))
                }
            } catch {
                clearingHistory.send(false)
                log.error("清空历史失败：\(error)")
                showClearHistoryResult(String(localized: .clearHistoryFailed))
            }
        }
    }

    private func showClearHistoryResult(_ message: String, style: NSAlert.Style = .warning) {
        Task { @MainActor in
            let alert = NSAlert.appAlert()
            alert.alertStyle = style
            alert.messageText = message
            alert.addButton(withTitle: String(localized: .commonConfirm))
            if let window = SettingWindowController.shared.window, window.isVisible {
                _ = await alert.beginSheetModal(for: window)
            } else {
                alert.runModal()
            }
        }
    }

    func updateDbItem(id: Int64, item: PasteboardModel) {
        Task {
            await sqlManager.update(id: id, item: item)
        }
    }

    func updateItemGroupInDB(id: Int64, groupId: Int) async {
        await sqlManager.updateItemGroup(id: id, groupId: groupId)
        await MainActor.run {
            SyncEngine.shared.markDirtyAndSchedule()
        }
    }

    func updateItemHidden(itemId: Int64, hidden: Bool) {
        if let model = dataList.value.first(where: { $0.id == itemId }),
           hidden != model.hidden {
            model.updateHidden(val: hidden)
        }

        enqueueMutation { [sqlManager] in
            await sqlManager.updateItemHidden(id: itemId, hidden: hidden)
            await MainActor.run {
                SyncEngine.shared.markDirtyAndSchedule()
            }
        }
    }

    func updateItemGroup(id: Int64, groupId: Int) {
        enqueueMutation { [sqlManager] in
            await sqlManager.updateItemGroup(id: id, groupId: groupId)
            await MainActor.run {
                SyncEngine.shared.markDirtyAndSchedule()
            }
        }
    }

    func getCountByGroup(groupId: Int) async -> Int {
        await PasteReadStore.shared.getCountByGroup(groupId: groupId)
    }
}
