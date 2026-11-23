//
//  PasteDataStore.swift
//  Clipboard
//
//  Created by crown on 2025/9/15.
//

import AppKit
import Combine
import Darwin
import SQLite
import SQLite3
import SwiftUI

typealias Expression = SQLite.Expression

final class PasteDataStore {
    static let main = PasteDataStore()
    let pageSize = 50
    /// 搜索模式下条目统计截断阈值（展示 500+）
    static let filteredCountCap = 500

    private var memoryPressureSource: (any DispatchSourceMemoryPressure)?

    private init() {
        setupMemoryPressureHandler()
    }

    private func setupMemoryPressureHandler() {
        let source = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: .main)
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated {
                self?.trimExcessMemory(forceCachesOnly: WindowManager.shared.isVisible)
            }
        }
        source.resume()
        memoryPressureSource = source
    }

    @MainActor
    func trimExcessMemory(forceCachesOnly: Bool = false) {
        if !forceCachesOnly, !WindowManager.shared.isVisible {
            for model in dataList.value {
                model.clearLoadedPayload()
            }
            if dataList.value.count > pageSize {
                hasMoreData = true
                lastRequestedPage = 0
                pageIndex = 0
                updateData(with: Array(dataList.value.prefix(pageSize)), changeType: .reset)
            }
            trimmedUpToIndex = 0
            ClipUndoStore.shared.removeAll()
            PasteDataPointReader.closeConnection()
            WindowManager.shared.releaseHiddenWindowPayloads()
        } else {
            for model in dataList.value {
                model.evictRawData()
            }
        }
        AppIconCache.shared.trimMemory()
        FileThumbnailService.shared.clearCache()
        ModelThumbnailCache.shared.removeAll()
        ModelAttributedTextCache.shared.removeAll()
        ModelShowDataCache.shared.removeAll()
        ModelLinkMetadataCache.shared.removeAll()
        ClipContentRenderer.clearCache()
        sqlite3_release_memory(Int32.max)
        malloc_zone_pressure_relief(malloc_default_zone(), 0)
    }
    /// 截断扫描查询行数上限（达到 501 即可提前终止）
    static let countScanLimit = filteredCountCap + 1

    private(set) var dataList = CurrentValueSubject<[PasteboardModel], Never>([])

    /// UI 筛选与检索状态机
    let filterState = ClipboardFilterState.shared

    var searchWord: String { filterState.criteria.keyword }
    private(set) var chipsVersion: Int = 0

    var totalCount: Int = 0
    var pageIndex = 0
    private var trimmedUpToIndex = 0
    var isLoadingPage = false
    var hasMoreData = false
    var listRevision = 0
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
    var lastRequestedPage = 0

    let sqlManager = PasteSQLManager.manager
    var searchTask: Task<Void, Error>?
    var countTask: Task<Void, Never>?
    var loadPageTask: Task<Void, Never>?
    var isReloading = false
    var repairingTagIds = Set<Int64>()
    let clearingHistory = CurrentValueSubject<Bool, Never>(false)
    /// 撤销恢复后希望定位的行；用 token 让多个窗口各自消费一次。
    private var focusRequest: (token: Int, index: Int)?
    private var focusToken = 0
    var orderRevision = 0
    var ingestionTask: Task<Void, Never>?
    var onDemandOCRTask: Task<Void, Never>?
    private var hasRegisteredStoreEvents = false
    /// 撤销进行中时忽略重复 ⌘Z，避免两次恢复交叉。
    var isUndoing = false
    /// 串行登记尚未落库的写操作（删除/移组/隐藏），撤销前只需等待队尾。
    private var mutationTail: Task<Void, Never>?

    func setup() async -> Bool {
        registerStoreEventSubscribersIfNeeded()
        guard await sqlManager.setup() else { return false }
        // 写入侧完成建表/迁移后再开只读连接，避免读到旧 schema。
        guard await PasteReadStore.shared.setup() else { return false }
        SourceAppCache.shared.replace(await sqlManager.getDistinctAppInfo())
        await resetDefaultList()
        let count = await sqlManager.getTotalCount()
        totalCount = count
        filterState.filteredCount = count
        malloc_zone_pressure_relief(malloc_default_zone(), 0)
        Task {
            await ColdArchiveManager.shared.scheduleIdleArchivingIfNeeded()
        }
        return true
    }

    private func registerStoreEventSubscribersIfNeeded() {
        guard !hasRegisteredStoreEvents else { return }
        hasRegisteredStoreEvents = true

        ClipStoreEventBus.shared.subscribe { event in
            switch event {
            case let .itemsDeleted(uniqueIds, hotIds):
                if !uniqueIds.isEmpty {
                    SyncPendingDeletionsStore.shared.recordDeletions(uniqueIds: uniqueIds)
                    Task { @MainActor in
                        SyncEngine.shared.markDirtyAndSchedule()
                    }
                }
                if !hotIds.isEmpty {
                    Task { @MainActor in
                        DeferredOCRCoordinator.shared.remove(ids: hotIds)
                    }
                }

            case let .itemGroupUpdated(uniqueId, groupId):
                let onlySyncPinned = UserDefaults.standard.object(forKey: "sync_only_pinned") == nil
                    ? true
                    : UserDefaults.standard.bool(forKey: "sync_only_pinned")
                if groupId == -1 {
                    if onlySyncPinned {
                        SyncPendingDeletionsStore.shared.recordDeletions(uniqueIds: [uniqueId])
                    }
                } else {
                    SyncPendingDeletionsStore.shared.removeDeletions(uniqueIds: [uniqueId])
                }
            }
        }
    }

    func notifyCategoryChipsChanged() {
        chipsVersion &+= 1
    }

    func resetPaginationForPromotion(visibleCount: Int) {
        loadPageTask?.cancel()
        loadPageTask = nil
        isLoadingPage = false
        pageIndex = 0
        lastRequestedPage = 0
        let effectiveTotal = isInFilterMode ? filteredCount : totalCount
        hasMoreData = isInFilterMode
            ? (isFilteredCountCapped || effectiveTotal > visibleCount)
            : (effectiveTotal > visibleCount)
    }

    func updateData(
        with list: [PasteboardModel],
        changeType: DataChangeType = .reset
    ) {
        if changeType != .loadMore {
            trimmedUpToIndex = 0
        }
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
            guard !Task.isCancelled else { return }
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
        let idSet = Set(ids)
        return list.firstIndex { model in
            guard let id = model.id else { return false }
            return idSet.contains(id)
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
            let deduplicated = newItems.filter { !existingUniqueIds.contains($0.uniqueId) }

            if !deduplicated.isEmpty {
                list.append(contentsOf: deduplicated)
                // 滑动窗口清理：若已加载条目超过 150 条（3页），对距离当前尾部超过 150 条的前端模型轻量清理运行时渲染产物
                if list.count > pageSize * 3 {
                    let trimEndIndex = list.count - (pageSize * 3)
                    if trimEndIndex > self.trimmedUpToIndex {
                        for i in self.trimmedUpToIndex..<trimEndIndex {
                            list[i].clearLoadedPayload()
                        }
                        self.trimmedUpToIndex = trimEndIndex
                    }
                }
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
        for _ in 0..<3 {
            guard !Task.isCancelled else { return }
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
        }, uniquingKeysWith: { first, _ in first })
        for entry in entries {
            models[entry.id]?.sortOrder = entry.order
        }
        let sorted = dataList.value.sorted {
            if $0.sortOrder != $1.sortOrder {
                return $0.sortOrder > $1.sortOrder
            }
            return ($0.id ?? 0) > ($1.id ?? 0)
        }
        updateData(with: sorted, changeType: .reorder)
    }
}
