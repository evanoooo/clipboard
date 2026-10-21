//
//  PasteDataStore.swift
//  Clipboard
//
//  Created by crown on 2025/9/15.
//

import AppKit
import Combine
import SQLite
import SwiftUI

typealias Expression = SQLite.Expression

final class PasteDataStore {
    static let main = PasteDataStore()
    let pageSize = 50

    private(set) var dataList = CurrentValueSubject<[PasteboardModel], Never>([])

    private(set) var searchWord: String = ""
    private(set) var chipsVersion: Int = 0

    var totalCount: Int = 0
    private(set) var pageIndex = 0
    private(set) var isLoadingPage = false
    private(set) var hasMoreData = false
    private(set) var listRevision = 0
    private(set) var filterRevision = 0
    private(set) var isReordering = false
    var filteredCount: Int = 0

    enum DataChangeType {
        case loadMore
        case searchFilter
        case reset
        case new
        case delete
        case moveToFirst
        case update
        case reorder
    }

    private(set) var lastDataChangeType: DataChangeType = .reset

    private(set) var currentFilter: Expression<Bool>?
    private(set) var isInFilterMode: Bool = false
    private var lastRequestedPage = 0

    let sqlManager = PasteSQLManager.manager
    private var searchTask: Task<Void, Error>?
    private var loadPageTask: Task<Void, Never>?
    private var isReloading = false
    var repairingTagIds = Set<Int64>()
    let clearingHistory = CurrentValueSubject<Bool, Never>(false)
    private var orderRevision = 0
    private var ingestionTask: Task<Void, Never>?

    func setup() async -> Bool {
        guard await sqlManager.setup() else { return false }
        SourceAppCache.shared.replace(await sqlManager.getDistinctAppInfo())
        await resetDefaultList()
        let count = await sqlManager.getTotalCount()
        totalCount = count
        filteredCount = count
        SourceAppCache.shared.warmMissingIcons()
        return true
    }

    func notifyCategoryChipsChanged() {
        chipsVersion &+= 1
    }

    func updateData(
        with list: [PasteboardModel],
        changeType: DataChangeType = .reset
    ) {
        listRevision &+= 1
        lastDataChangeType = changeType
        dataList.send(list)
    }

    func setHasMoreData(_ value: Bool) {
        hasMoreData = value
    }
}

// MARK: - 数据操作

extension PasteDataStore {
    func loadNextPage() {
        guard !isLoadingPage, !isReordering, !isReloading else { return }
        let effectiveTotal = isInFilterMode ? filteredCount : totalCount
        guard dataList.value.count < effectiveTotal else { return }

        let nextPage = pageIndex + 1
        guard nextPage != lastRequestedPage else { return }

        loadPageTask?.cancel()

        isLoadingPage = true
        lastRequestedPage = nextPage
        pageIndex = nextPage

        let currentOffset = dataList.value.count
        let filter = isInFilterMode ? currentFilter : nil

        log.debug(
            "loadNextPage \(pageIndex) (filterMode: \(isInFilterMode))"
        )

        loadPageTask = Task { [weak self] in
            guard let self else { return }

            let newItems: [PasteboardModel]
            if let filter {
                let rows = await sqlManager.search(
                    filter: filter,
                    limit: pageSize,
                    offset: currentOffset
                )
                newItems = await mapRows(rows)
            } else {
                newItems = await getItems(
                    limit: pageSize,
                    offset: currentOffset
                )
            }

            guard !Task.isCancelled else { return }

            guard !newItems.isEmpty else {
                hasMoreData = false
                isLoadingPage = false
                return
            }

            var list = dataList.value
            list += newItems

            updateData(with: list, changeType: .loadMore)
            hasMoreData = (newItems.count == pageSize)
            isLoadingPage = false
        }
    }

    func resetDefaultList() async {
        pageIndex = 0
        currentFilter = nil
        isInFilterMode = false
        searchWord = ""
        let list = await getItems(limit: pageSize, offset: pageSize * pageIndex)
        filteredCount = totalCount
        updateData(with: list)
        hasMoreData = list.count == pageSize
    }

    func resetToDefault() {
        filterRevision &+= 1
        listRevision &+= 1
        searchTask?.cancel()
        loadPageTask?.cancel()
        isLoadingPage = false
        lastRequestedPage = 0
        Task {
            await resetDefaultList()
        }
    }

    /// 数据库提交成功后再发布顺序，失败时维持当前列表。
    func reorderItems(_ ids: [Int64], before: Int64?, after: Int64?) async -> Bool {
        guard !isReordering else { return false }
        isReordering = true
        defer { isReordering = false }
        loadPageTask?.cancel()
        isLoadingPage = false
        lastRequestedPage = max(0, (dataList.value.count - 1) / pageSize)
        pageIndex = lastRequestedPage
        let revision = listRevision
        guard let order = await sqlManager.reorderItems(ids, before: before, after: after) else { return false }
        orderRevision &+= 1

        if revision == listRevision {
            applyOrder(order)
        } else {
            // await 期间有新内容或切换筛选时，按最新数据库顺序同步，保留当前列表成员。
            await refreshOrder()
        }
        return true
    }

    private func refreshOrder() async {
        while !Task.isCancelled {
            let revision = listRevision
            guard let order = await sqlManager.orderedItemIDs() else { return }
            guard revision == listRevision else { continue }
            applyOrder(order)
            return
        }
    }

    private func applyOrder(_ ids: [Int64]) {
        let models = Dictionary(dataList.value.compactMap { model in
            model.id.map { ($0, model) }
        }, uniquingKeysWith: { first, _ in first })
        updateData(with: ids.compactMap { models[$0] }, changeType: .reorder)
    }

    /// 数据搜索（关键词 + 自定义分组 + 过滤视图）
    func searchData(_ criteria: SearchCriteria) {
        filterRevision &+= 1
        searchTask?.cancel()
        loadPageTask?.cancel()
        isLoadingPage = false
        listRevision &+= 1

        searchTask = Task {
            let started = ContinuousClock.now
            let filter = PasteFilterBuilder.buildFilter(from: criteria)

            searchWord = criteria.keyword
            currentFilter = filter
            isInFilterMode = (filter != nil)
            pageIndex = 0
            lastRequestedPage = 0

            var result: [PasteboardModel]
            var revision: Int
            var rowCount = 0
            var sqlElapsed: Duration = .zero
            var countElapsed: Duration = .zero
            var mapElapsed: Duration = .zero
            repeat {
                revision = orderRevision
                let sqlStarted = ContinuousClock.now
                let rows = await sqlManager.search(filter: filter, limit: pageSize)
                sqlElapsed = sqlStarted.duration(to: .now)
                rowCount = rows.count
                try Task.checkCancellation()
                let mapStarted = ContinuousClock.now
                result = await mapRows(rows)
                mapElapsed = mapStarted.duration(to: .now)
            } while revision != orderRevision

            // 页未满时命中数就是总数，省掉一次全表扫描；页满才需要精确计数。
            // 以 SQL 返回行数为准，避免 mapRows 丢行导致总数偏小。
            let needsCount = rowCount == pageSize
            let total: Int
            if needsCount {
                let countStarted = ContinuousClock.now
                total = await sqlManager.getCount(filter: filter)
                countElapsed = countStarted.duration(to: .now)
                try Task.checkCancellation()
            } else {
                total = rowCount
            }

            filteredCount = total
            let dbElapsed = started.duration(to: .now)
            let publishStarted = ContinuousClock.now
            updateData(with: result, changeType: .searchFilter)
            hasMoreData = rowCount == pageSize

            logSearch(criteria, filter: filter, rows: rowCount, result: result, total: total,
                      countScan: needsCount, sqlElapsed: sqlElapsed, countElapsed: countElapsed,
                      mapElapsed: mapElapsed, elapsed: dbElapsed,
                      publishElapsed: publishStarted.duration(to: .now))
        }
    }

    /// 搜索性能日志：固定前缀与字段顺序，便于横向对比不同实现的耗时。
    private func logSearch(
        _ criteria: SearchCriteria,
        filter: Expression<Bool>?,
        rows: Int,
        result: [PasteboardModel],
        total: Int,
        countScan: Bool,
        sqlElapsed: Duration,
        countElapsed: Duration,
        mapElapsed: Duration,
        elapsed: Duration,
        publishElapsed: Duration
    ) {
        let tokens = SearchTextNormalizer.queryTokens(criteria.keyword).count
        let payload = result.reduce(0) { $0 + $1.data.count }
        let message = "[search] kw=\"\(criteria.keyword)\" tokens=\(tokens) "
            + "rows=\(rows) mapped=\(result.count) total=\(total) countScan=\(countScan) "
            + "filters=\(filter != nil ? 1 : 0) "
            + "sql=\(sqlElapsed.millisecondsText) count=\(countElapsed.millisecondsText) "
            + "map=\(mapElapsed.millisecondsText) publish=\(publishElapsed.millisecondsText) "
            + "db=\(elapsed.millisecondsText) "
            + "payload=\(payload.formatted(.byteCount(style: .memory)))"
        // 分别关注「数据库慢」与「发布/渲染慢」，两者堆到一起会掩盖真实瓶颈。
        if elapsed.milliseconds >= 100 || publishElapsed.milliseconds >= 100 {
            log.warn(message)
        } else {
            log.info(message)
        }
    }

    @discardableResult
    func addNewItem(_ item: NSPasteboard, sourceApp: NSRunningApplication? = nil, chipId: Int = -1) -> Bool {
        if let first = item.pasteboardItems?.first,
           first.availableType(from: PasteboardType.supportTypes) == .string,
           PasteboardModel.extractFilePaths(from: item, item: first) == nil,
           let data = first.data(forType: .string), data.count > 1_048_576 {
            ingestionTask = ingestText(data, sourceApp: sourceApp, chipId: chipId, after: ingestionTask)
            return true
        }
        guard let model = PasteboardModel(with: item, sourceApp: sourceApp) else { return false }

        if chipId != -1 {
            model.updateGroup(val: chipId)
        }

        PasteMetadataCache.shared.invalidateTagTypesCache(model)

        let previous = ingestionTask
        ingestionTask = Task {
            await previous?.value
            await insertModel(model)
            await runOCRIfNeeded(model)
        }
        return true
    }

    func runOCRIfNeeded(_ model: PasteboardModel) async {
        guard model.type == .image, let id = model.id else { return }

        let rawText = await OCRViewService.shared.recognizeText(
            from: model.data
        )

        guard !rawText.isEmpty else { return }

        let searchText = PasteboardModel.normalizeSearchText(rawText)
        model.updateSearchText(val: searchText)
        await sqlManager.update(id: id, item: model)
    }

    private func prepareApp(for model: PasteboardModel) async -> Bool {
        do {
            let id: Int64
            if let existing = model.appID {
                id = existing
            } else {
                id = try await sqlManager.resolveApp(
                    name: model.appName, path: model.appPath, bundleID: model.sourceBundleID
                )
            }
            model.appID = id
            return true
        } catch {
            log.error("保存来源应用失败：\(error)")
            return false
        }
    }

    func insertModel(_ model: PasteboardModel) async {
        guard await prepareApp(for: model) else { return }
        let result = await sqlManager.insert(
            item: model,
            timestamp: model.timestamp,
            group: model.group
        )
        guard result.id >= 0 else { return }
        model.appID = result.appID
        await sqlManager.refreshAppCache()
        AppColorService.shared.updateColor(for: model)
        let count = await sqlManager.getTotalCount()

        model.id = result.id
        if let group = result.group {
            model.updateGroup(val: group)
        }
        totalCount = count

        if isInFilterMode, let filter = currentFilter {
            filteredCount = await sqlManager.getCount(filter: filter)
            guard let id = model.id,
                  await sqlManager.getCount(filter: filter && Col.id == id) > 0
            else { return }
        } else {
            filteredCount = count
        }

        var list = dataList.value
        list.removeAll(where: { $0.uniqueId == model.uniqueId })
        list.insert(model, at: 0)
        let truncated = Array(list.prefix(pageSize))
        hasMoreData = list.count >= pageSize

        pageIndex = 0
        lastRequestedPage = 0
        loadPageTask?.cancel()
        isLoadingPage = false

        updateData(with: truncated, changeType: .new)
    }

    func reloadHistory() async {
        guard !isReloading else { return }
        isReloading = true
        defer { isReloading = false }
        loadPageTask?.cancel()
        searchTask?.cancel()
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
        let loadedLimit = max(pageSize, dataList.value.count)
        loadPageTask?.cancel()
        isLoadingPage = false

        guard await sqlManager.updateItemContent(
            id: id,
            content: content,
            searchText: searchText
        ) else {
            return false
        }

        let list: [PasteboardModel]
        if isInFilterMode, let currentFilter {
            let rows = await sqlManager.search(
                filter: currentFilter,
                limit: loadedLimit
            )
            list = await mapRows(rows)
        } else {
            list = await getItems(limit: loadedLimit)
        }

        totalCount = await sqlManager.getTotalCount()
        if isInFilterMode, let currentFilter {
            filteredCount = await sqlManager.getCount(filter: currentFilter)
        } else {
            filteredCount = totalCount
        }
        let effectiveTotal = isInFilterMode ? filteredCount : totalCount
        hasMoreData = list.count < effectiveTotal
        pageIndex = max(0, (list.count - 1) / pageSize)
        lastRequestedPage = pageIndex
        updateData(with: list, changeType: .moveToFirst)
        return true
    }

    /// 更新别名。别名不参与类型判定，只影响关键词命中，因此按当前筛选结果刷新。
    @discardableResult
    func updateAlias(id: Int64, alias: String) async -> Bool {
        guard await sqlManager.updateItemAlias(id: id, alias: alias) else { return false }

        let trimmed = alias.trimmingCharacters(in: .whitespacesAndNewlines)
        if let model = dataList.value.first(where: { $0.id == id }) {
            model.updateAlias(val: trimmed)
        }

        guard isInFilterMode, let currentFilter else {
            updateData(with: dataList.value, changeType: .update)
            return true
        }

        let loadedLimit = max(pageSize, dataList.value.count)
        let rows = await sqlManager.search(filter: currentFilter, limit: loadedLimit)
        // 复用已有实例（仅别名字段变化），命中集合不变时无需重建快照。
        let existing = Dictionary(dataList.value.compactMap { model in
            model.id.map { ($0, model) }
        }, uniquingKeysWith: { first, _ in first })
        let list = await mapRows(rows).map { model in
            model.id.flatMap { existing[$0] } ?? model
        }
        filteredCount = await sqlManager.getCount(filter: currentFilter)
        hasMoreData = list.count < filteredCount
        pageIndex = max(0, (list.count - 1) / pageSize)
        lastRequestedPage = pageIndex

        // 命中集合变化时必须重建快照，否则被别名搜索排除的卡片会留在原地。
        let membershipChanged = Set(dataList.value.map(\.uniqueId)) != Set(list.map(\.uniqueId))
        updateData(with: list, changeType: membershipChanged ? .searchFilter : .update)
        return true
    }

}
