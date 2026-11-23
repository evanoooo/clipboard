//
//  PasteDataStore+Updates.swift
//  Clipboard
//
//  列表全量重载以及单条记录内容、别名的局部增量刷新
//

import Combine
import Foundation
import SQLite

extension PasteDataStore {
    func reloadHistory() async {
        guard !isReloading else { return }
        isReloading = true
        defer { isReloading = false }
        loadPageTask?.cancel()
        searchTask?.cancel()
        countTask?.cancel()
        isLoadingPage = false
        guard let list = await loadHistoryPage() else { return }
        pageIndex = 0
        lastRequestedPage = 0
        updateData(with: list, changeType: .delete)
    }

    /// 编辑更新
    func updateItemContent(
        id: Int64,
        content: PasteContent,
        searchText: String
    ) async -> Bool {
        loadPageTask?.cancel()
        isLoadingPage = false

        let existingUniqueId = dataList.value.first(where: { $0.id == id })?.uniqueId
        guard await sqlManager.updateItemContent(
            id: id,
            content: content,
            searchText: searchText,
            uniqueId: existingUniqueId
        ) else {
            return false
        }

        let updatedUniqueId = PasteboardModel.generateUniqueId(for: content.type, data: content.data)
        // 增量局部刷新：按最新 uniqueId 单点重查被修改的单行，兼顾热库主键与冷库回温场景
        let singleRow = await PasteReadStore.shared.search(
            filter: Col.uniqueId == updatedUniqueId,
            limit: 1
        )
        guard let updatedModel = (await mapRows(singleRow)).first else {
            return false
        }

        var list = dataList.value
        list.removeAll {
            $0.id == id
                || $0.uniqueId == updatedModel.uniqueId
                || (existingUniqueId != nil && $0.uniqueId == existingUniqueId)
        }
        list.insert(updatedModel, at: 0)

        totalCount = await sqlManager.getTotalCount()
        if isInFilterMode, let currentFilter {
            let scanned = await PasteReadStore.shared.getCount(filter: currentFilter, limit: Self.countScanLimit)
            updateFilteredCount(scanned: scanned)
        } else {
            filterState.filteredCount = totalCount
            filterState.isCountCapped = false
            countUpdated.send()
        }
        let effectiveTotal = isInFilterMode ? filteredCount : totalCount
        hasMoreData = isFilteredCountCapped || list.count < effectiveTotal
        pageIndex = max(0, (list.count - 1) / pageSize)
        lastRequestedPage = pageIndex
        updateData(with: list, changeType: .moveToFirst)
        await MainActor.run {
            SyncEngine.shared.markDirtyAndSchedule()
        }
        return true
    }

    /// 更新别名。别名不参与类型判定，只影响关键词命中，因此按当前筛选结果刷新。
    @discardableResult
    func updateAlias(id: Int64, alias: String) async -> Bool {
        let existingModel = dataList.value.first(where: { $0.id == id })
        let uniqueId = existingModel?.uniqueId
        guard await sqlManager.updateItemAlias(id: id, alias: alias, uniqueId: uniqueId) else { return false }
        await MainActor.run {
            SyncEngine.shared.markDirtyAndSchedule()
        }

        let trimmed = alias.trimmingCharacters(in: .whitespacesAndNewlines)
        existingModel?.updateAlias(val: trimmed)

        guard isInFilterMode, let currentFilter else {
            updateData(with: dataList.value, changeType: .update)
            return true
        }

        let loadedLimit = max(pageSize, dataList.value.count)
        let rows = await PasteReadStore.shared.search(filter: currentFilter, limit: loadedLimit)
        // 复用已有实例（仅别名字段变化），命中集合不变时无需重建快照。
        let existing = Dictionary(dataList.value.compactMap { model in
            model.id.map { ($0, model) }
        }, uniquingKeysWith: { first, _ in first })
        let list = await mapRows(rows).map { model in
            model.id.flatMap { existing[$0] } ?? model
        }
        let scanned = await PasteReadStore.shared.getCount(filter: currentFilter, limit: Self.countScanLimit)
        updateFilteredCount(scanned: scanned)
        hasMoreData = isFilteredCountCapped || list.count < filteredCount
        pageIndex = max(0, (list.count - 1) / pageSize)
        lastRequestedPage = pageIndex

        // 命中集合变化时必须重建快照，否则被别名搜索排除的卡片会留在原地。
        let membershipChanged = Set(dataList.value.map(\.uniqueId)) != Set(list.map(\.uniqueId))
        updateData(with: list, changeType: membershipChanged ? .searchFilter : .update)
        return true
    }
}
