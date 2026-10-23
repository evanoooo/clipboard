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
    /// 搜索模式下条目统计截断阈值（展示 500+）
    static let filteredCountCap = 500

    @MainActor
    func trimExcessMemory() {
        guard !WindowManager.shared.isVisible else { return }
        if dataList.value.count > pageSize {
            dataList.value = Array(dataList.value.prefix(pageSize))
            hasMoreData = true
            lastRequestedPage = 0
            pageIndex = 0
        }
        for model in dataList.value {
            model.cachedHighlightedCode = nil
            model.cachedPlainTextAttributedString = nil
            model.clearLoadedPayload()
        }
    }
    /// 截断扫描查询行数上限（达到 501 即可提前终止）
    static let countScanLimit = filteredCountCap + 1

    private(set) var dataList = CurrentValueSubject<[PasteboardModel], Never>([])

    /// UI 筛选与检索状态机
    let filterState = ClipboardFilterState.shared

    var searchWord: String { filterState.criteria.keyword }
    private(set) var chipsVersion: Int = 0

    var totalCount: Int = 0
    private(set) var pageIndex = 0
    private(set) var isLoadingPage = false
    private(set) var hasMoreData = false
    private(set) var listRevision = 0
    private(set) var isReordering = false

    /// 兼容委托至 filterState
    var currentFilter: Expression<Bool>? {
        get { filterState.currentFilter }
        set { filterState.setFilter(newValue) }
    }
    var isInFilterMode: Bool { filterState.isInFilterMode }
    var filteredCount: Int {
        get { filterState.filteredCount }
        set { filterState.filteredCount = newValue }
    }
    var isFilteredCountCapped: Bool {
        get { filterState.isCountCapped }
        set { filterState.isCountCapped = newValue }
    }
    var filterRevision: Int { filterState.revision }

    /// 通知底部状态栏或外部视图刷新计数
    let countUpdated = PassthroughSubject<Void, Never>()

    /// 统一收敛更新筛选模式下的条目计数与截断标记
    func updateFilteredCount(scanned: Int) {
        let isCapped = scanned > Self.filteredCountCap
        filterState.filteredCount = isCapped ? Self.filteredCountCap : scanned
        filterState.isCountCapped = isCapped
        countUpdated.send()
    }

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
    private var lastRequestedPage = 0

    let sqlManager = PasteSQLManager.manager
    private var searchTask: Task<Void, Error>?
    private var countTask: Task<Void, Never>?
    private var loadPageTask: Task<Void, Never>?
    private var isReloading = false
    var repairingTagIds = Set<Int64>()
    let clearingHistory = CurrentValueSubject<Bool, Never>(false)
    /// 撤销恢复后希望定位的行；用 token 让多个窗口各自消费一次。
    private var focusRequest: (token: Int, index: Int)?
    private var focusToken = 0
    private var orderRevision = 0
    private var ingestionTask: Task<Void, Never>?
    /// 撤销进行中时忽略重复 ⌘Z，避免两次恢复交叉。
    var isUndoing = false
    /// 串行登记尚未落库的写操作（删除/移组/隐藏），撤销前只需等待队尾。
    private var mutationTail: Task<Void, Never>?

    func setup() async -> Bool {
        guard await sqlManager.setup() else { return false }
        // 写入侧完成建表/迁移后再开只读连接，避免读到旧 schema。
        guard await PasteReadStore.shared.setup() else { return false }
        SourceAppCache.shared.replace(await sqlManager.getDistinctAppInfo())
        await resetDefaultList()
        let count = await sqlManager.getTotalCount()
        totalCount = count
        filterState.filteredCount = count
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

    /// 写操作排队执行，保证撤销时的恢复不会被尚未落库的删除/移组覆盖。
    func enqueueMutation(_ operation: @escaping () async -> Void) {
        let previous = mutationTail
        mutationTail = Task {
            await previous?.value
            await operation()
        }
    }

    func awaitPendingMutations() async {
        await mutationTail?.value
    }

    /// 重新发布列表前重置分页状态，并停掉可能在飞的翻页/搜索任务。
    func resetPagination() {
        loadPageTask?.cancel()
        searchTask?.cancel()
        countTask?.cancel()
        pageIndex = 0
        lastRequestedPage = 0
        isLoadingPage = false
    }

    /// 请求列表在应用完快照后聚焦到指定行；传 nil 清除未消费的请求。
    func requestFocus(at index: Int?) {
        guard let index else {
            focusRequest = nil
            return
        }
        focusToken &+= 1
        focusRequest = (focusToken, index)
    }

    /// 主窗与浮窗共享同一份数据，各自持有已处理的 token，互不抢占。
    func pendingFocus(after token: Int) -> (token: Int, index: Int)? {
        guard let focusRequest, focusRequest.token != token else { return nil }
        return focusRequest
    }

    func focusIndex(in list: [PasteboardModel], ids: [Int64]) -> Int? {
        guard !ids.isEmpty else { return nil }
        return list.firstIndex { model in
            guard let id = model.id else { return false }
            return ids.contains(id)
        }
    }
}

// MARK: - 数据操作

extension PasteDataStore {
    func loadNextPage() {
        guard !isLoadingPage, !isReordering, !isReloading else { return }
        let effectiveTotal = isInFilterMode ? filteredCount : totalCount
        guard isFilteredCountCapped || dataList.value.count < effectiveTotal else { return }

        let nextPage = pageIndex + 1
        guard nextPage != lastRequestedPage else { return }

        loadPageTask?.cancel()

        isLoadingPage = true
        lastRequestedPage = nextPage
        pageIndex = nextPage

        let currentOffset = dataList.value.count
        let filter = isInFilterMode ? currentFilter : nil
        let capturedFilterRevision = filterRevision
        let capturedListRevision = listRevision

        log.debug(
            "loadNextPage \(pageIndex) (filterMode: \(isInFilterMode))"
        )

        loadPageTask = Task { [weak self] in
            guard let self else { return }

            let newItems: [PasteboardModel]
            if let filter {
                let rows = await PasteReadStore.shared.search(
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

            guard !Task.isCancelled,
                  self.filterRevision == capturedFilterRevision,
                  self.listRevision == capturedListRevision else {
                self.isLoadingPage = false
                return
            }

            guard !newItems.isEmpty else {
                self.hasMoreData = false
                self.isLoadingPage = false
                return
            }

            var list = self.dataList.value
            let existingUniqueIds = Set(list.map(\.uniqueId))
            let existingDbIds = Set(list.compactMap(\.id))
            let deduplicated = newItems.filter { item in
                if existingUniqueIds.contains(item.uniqueId) { return false }
                if let id = item.id, existingDbIds.contains(id) { return false }
                return true
            }

            if !deduplicated.isEmpty {
                list.append(contentsOf: deduplicated)
                self.updateData(with: list, changeType: .loadMore)
            }

            self.hasMoreData = (newItems.count == pageSize && (self.isFilteredCountCapped || list.count < effectiveTotal))
            self.isLoadingPage = false
        }
    }

    func resetDefaultList(focusIds: [Int64] = [], limit: Int? = nil) async {
        pageIndex = 0
        filterState.reset()
        let size = max(limit ?? pageSize, pageSize)
        let list = await getItems(limit: size, offset: 0)
        filterState.filteredCount = totalCount
        countUpdated.send()
        requestFocus(at: focusIndex(in: list, ids: focusIds))
        updateData(with: list)
        hasMoreData = list.count == size
    }

    func resetToDefault() {
        filterState.reset()
        listRevision &+= 1
        searchTask?.cancel()
        countTask?.cancel()
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
        guard let entries = await sqlManager.reorderItems(ids, before: before, after: after) else { return false }
        orderRevision &+= 1

        if revision == listRevision {
            applyOrder(entries)
        } else {
            // await 期间有新内容或切换筛选时，按最新数据库顺序同步，保留当前列表成员。
            await refreshOrder()
        }
        return true
    }

    private func refreshOrder() async {
        while !Task.isCancelled {
            let revision = listRevision
            guard let entries = await sqlManager.orderedItemEntries() else { return }
            guard revision == listRevision else { continue }
            applyOrder(entries)
            return
        }
    }

    private func applyOrder(_ entries: [(id: Int64, order: Int64)]) {
        let models = Dictionary(dataList.value.compactMap { model in
            model.id.map { ($0, model) }
        }, uniquingKeysWith: { first, _ in first } )
        let sorted = entries.compactMap { entry -> PasteboardModel? in
            guard let model = models[entry.id] else { return nil }
            model.sortOrder = entry.order
            return model
        }
        updateData(with: sorted, changeType: .reorder)
    }

    /// 数据搜索（关键字 + 自定义分组 + 过滤视图）
    func searchData(_ criteria: SearchCriteria) {
        let filter = filterState.update(criteria: criteria)
        let capturedFilterRev = filterState.revision
        searchTask?.cancel()
        countTask?.cancel()
        loadPageTask?.cancel()
        isLoadingPage = false
        listRevision &+= 1
        let capturedListRev = listRevision

        searchTask = Task {
            let started = ContinuousClock.now
            pageIndex = 0
            lastRequestedPage = 0

            var result: [PasteboardModel]
            var revision: Int
            var rowCount = 0
            var sqlElapsed: Duration = .zero
            var mapElapsed: Duration = .zero
            repeat {
                revision = orderRevision
                let sqlStarted = ContinuousClock.now
                let rows = await PasteReadStore.shared.search(filter: filter, limit: pageSize)
                sqlElapsed = sqlStarted.duration(to: .now)
                rowCount = rows.count
                try Task.checkCancellation()
                let mapStarted = ContinuousClock.now
                result = await mapRows(rows)
                mapElapsed = mapStarted.duration(to: .now)
            } while revision != orderRevision

            try Task.checkCancellation()
            guard self.filterState.revision == capturedFilterRev, self.listRevision == capturedListRev else { return }

            let publishStarted = ContinuousClock.now

            // 【方案 1: 首屏数据立即发布】
            // 页未满时，说明总记录数就等于 rowCount，无需发起额外计数扫描
            if rowCount < pageSize {
                self.filterState.filteredCount = rowCount
                self.filterState.isCountCapped = false
                self.hasMoreData = false
                self.updateData(with: result, changeType: .searchFilter)
                self.countUpdated.send()

                let dbElapsed = started.duration(to: .now)
                logSearch(criteria, filter: filter, rows: rowCount, result: result, total: rowCount,
                          isCapped: false, countScan: false, sqlElapsed: sqlElapsed, countElapsed: .zero,
                          mapElapsed: mapElapsed, elapsed: dbElapsed,
                          publishElapsed: publishStarted.duration(to: .now))
                return
            }

            // 首屏满页 (rowCount == pageSize)：有更多数据。立即向 UI 发布首屏结果，响应时间从 ~285ms 直降到 ~17ms！
            self.filterState.filteredCount = rowCount
            self.filterState.isCountCapped = false
            self.hasMoreData = true
            self.updateData(with: result, changeType: .searchFilter)
            let firstPagePublishElapsed = publishStarted.duration(to: .now)

            // 【方案 2: 大于500条截断计数 / 异步统计】
            // 在后台非阻塞执行截断计数扫描（上限 501），避免扫描全表数千行大字段产生几百毫秒卡顿
            self.startAsyncCountTask(
                filter: filter,
                criteria: criteria,
                capturedFilterRev: capturedFilterRev,
                capturedListRev: capturedListRev,
                rowCount: rowCount,
                result: result,
                sqlElapsed: sqlElapsed,
                mapElapsed: mapElapsed,
                started: started,
                publishElapsed: firstPagePublishElapsed
            )
        }
    }

    private func startAsyncCountTask(
        filter: Expression<Bool>?,
        criteria: SearchCriteria,
        capturedFilterRev: Int,
        capturedListRev: Int,
        rowCount: Int,
        result: [PasteboardModel],
        sqlElapsed: Duration,
        mapElapsed: Duration,
        started: ContinuousClock.Instant,
        publishElapsed: Duration
    ) {
        countTask = Task { [weak self] in
            guard let self else { return }
            let countStarted = ContinuousClock.now

            // 截断扫描：只要遇到第 501 条即终止扫描，耗时通常只需 1~3ms
            let scannedCount = await PasteReadStore.shared.getCount(filter: filter, limit: Self.countScanLimit)
            let countElapsed = countStarted.duration(to: .now)

            guard !Task.isCancelled,
                  self.filterState.revision == capturedFilterRev,
                  self.listRevision == capturedListRev else { return }

            let isCapped = scannedCount > Self.filteredCountCap
            let total = isCapped ? Self.filteredCountCap : scannedCount

            self.filterState.filteredCount = total
            self.filterState.isCountCapped = isCapped
            // 依据当前已加载量动态核定翻页状态，避免覆盖中间滚动加载的分页状态
            let currentLoaded = self.dataList.value.count
            self.hasMoreData = (rowCount == self.pageSize && (isCapped || currentLoaded < total))
            self.countUpdated.send()

            let totalElapsed = started.duration(to: .now)
            self.logSearch(
                criteria,
                filter: filter,
                rows: rowCount,
                result: result,
                total: total,
                isCapped: isCapped,
                countScan: true,
                sqlElapsed: sqlElapsed,
                countElapsed: countElapsed,
                mapElapsed: mapElapsed,
                elapsed: totalElapsed,
                publishElapsed: publishElapsed
            )
        }
    }

    /// 搜索性能日志：固定前缀与字段顺序，便于横向对比不同实现的耗时。
    private func logSearch(
        _ criteria: SearchCriteria,
        filter: Expression<Bool>?,
        rows: Int,
        result: [PasteboardModel],
        total: Int,
        isCapped: Bool = false,
        countScan: Bool,
        sqlElapsed: Duration,
        countElapsed: Duration,
        mapElapsed: Duration,
        elapsed: Duration,
        publishElapsed: Duration
    ) {
        let tokenList = SearchTextNormalizer.queryTokens(criteria.keyword)
        let lengths = tokenList.map(\.count)
        // Phase 0 采样：trigram 仅对 ≥3 字符的词元生效，据此判断是否值得引入 FTS。
        let minToken = lengths.min() ?? 0
        let maxToken = lengths.max() ?? 0
        let ftsEligible = !lengths.isEmpty && minToken >= 3
        let payload = result.reduce(0) { $0 + ($1.hasLoadedData ? $1.data.count : ($1.showData?.count ?? 0)) }
        let totalStr = isCapped ? "\(total)+" : "\(total)"
        let message = "[search] kwLen=\(criteria.keyword.count) tokens=\(tokenList.count) "
            + "rows=\(rows) mapped=\(result.count) total=\(totalStr) countScan=\(countScan) "
            + "filters=\(filter != nil ? 1 : 0) "
            + "sql=\(sqlElapsed.millisecondsText) count=\(countElapsed.millisecondsText) "
            + "map=\(mapElapsed.millisecondsText) publish=\(publishElapsed.millisecondsText) "
            + "db=\(elapsed.millisecondsText) "
            + "tokenMin=\(minToken) tokenMax=\(maxToken) fts=\(ftsEligible ? 1 : 0) "
            + "corpus=\(totalCount) kinds=\(Self.filterKinds(criteria)) "
            + "payload=\(payload.formatted(.byteCount(style: .memory)))"
        // 分别关注「数据库慢」与「发布/渲染慢」，两者堆在一起会掩盖真实瓶颈。
        if elapsed.milliseconds >= 100 || publishElapsed.milliseconds >= 100 {
            Log.database.warn(message)
        } else {
            Log.database.info(message)
        }
    }

    /// 压缩成短代码，便于离线统计哪类筛选组合在变慢。
    private static func filterKinds(_ criteria: SearchCriteria) -> String {
        var kinds: [String] = []
        if !criteria.keyword.isEmpty { kinds.append("k") }
        if !criteria.selectedGroupIds.isEmpty { kinds.append("g") }
        if !criteria.selectedTypes.isEmpty { kinds.append("t") }
        if !criteria.selectedAppIDs.isEmpty { kinds.append("a") }
        if criteria.selectedDateFilter != nil { kinds.append("d") }
        return kinds.isEmpty ? "-" : kinds.joined()
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

        let previous = ingestionTask
        ingestionTask = Task {
            await previous?.value
            await insertModel(model)
            SyncEngine.shared.markDirtyAndSchedule()
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

    /// 静默录入由云端同步拉取的条目（仅底层 SQLite 持久化并解析 App，不劫持当前内存剪贴板列表顶部，不触发即时动画）
    func ingestSyncedModel(_ model: PasteboardModel) async {
        guard await prepareApp(for: model) else { return }
        let result = await sqlManager.insert(
            item: model,
            timestamp: model.timestamp,
            group: model.group
        )
        guard result.id >= 0 else { return }
        model.id = result.id
        model.appID = result.appID
        model.sortOrder = result.sortOrder
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
        model.sortOrder = result.sortOrder
        if let group = result.group {
            model.updateGroup(val: group)
        }
        totalCount = count

        if isInFilterMode, let filter = currentFilter {
            if !isFilteredCountCapped {
                let scanned = await PasteReadStore.shared.getCount(filter: filter, limit: Self.countScanLimit)
                updateFilteredCount(scanned: scanned)
            } else {
                countUpdated.send()
            }
            guard let id = model.id,
                  await PasteReadStore.shared.getCount(filter: filter && Col.id == id) > 0
            else { return }
        } else {
            filterState.filteredCount = count
            filterState.isCountCapped = false
            countUpdated.send()
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
            let rows = await PasteReadStore.shared.search(
                filter: currentFilter,
                limit: loadedLimit
            )
            list = await mapRows(rows)
        } else {
            list = await getItems(limit: loadedLimit)
        }

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
