//
//  PasteDataStore+Search.swift
//  Clipboard
//
//  剪贴板检索、异步截断统计、过滤匹配校验与按需 OCR 触发
//

import Combine
import Foundation
import SQLite

extension PasteDataStore {
    /// 数据搜索（关键字 + 自定义分组 + 过滤视图）
    func searchData(_ criteria: SearchCriteria, triggerOCR: Bool = true) {
        let filter = filterState.update(criteria: criteria)
        let capturedFilterRev = filterState.revision
        if triggerOCR, !criteria.keyword.isEmpty {
            triggerOnDemandOCRFallback(for: criteria)
        }
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

            // 页未满时，说明总记录数就等于 rowCount，无需发起额外计数扫描
            if rowCount < pageSize {
                self.filterState.filteredCount = rowCount
                self.filterState.isCountCapped = false
                self.hasMoreData = false
                self.updateData(with: result, changeType: .searchFilter)
                self.countUpdated.send()

                let dbElapsed = started.duration(to: .now)
                logSearch(
                    criteria,
                    filter: filter,
                    rows: rowCount,
                    result: result,
                    total: rowCount,
                    isCapped: false,
                    countScan: false,
                    sqlElapsed: sqlElapsed,
                    countElapsed: .zero,
                    mapElapsed: mapElapsed,
                    elapsed: dbElapsed,
                    publishElapsed: publishStarted.duration(to: .now)
                )
                return
            }

            // 首屏满页 (rowCount == pageSize)：立即向 UI 发布首屏结果，再在后台截断统计
            self.filterState.filteredCount = rowCount
            self.filterState.isCountCapped = false
            self.hasMoreData = true
            self.updateData(with: result, changeType: .searchFilter)
            let firstPagePublishElapsed = publishStarted.duration(to: .now)

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
        let minToken = lengths.min() ?? 0
        let maxToken = lengths.max() ?? 0
        let ftsEligible = !lengths.isEmpty && minToken >= 3
        let payload = result.reduce(0) { $0 + ($1.hasLoadedData ? $1.data.count : ($1.loadedShowDataIfPresent?.count ?? 0)) }
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
        if elapsed.milliseconds >= 100 || publishElapsed.milliseconds >= 100 {
            Log.database.warn(message)
        } else {
            Log.database.info(message)
        }
    }

    private static func filterKinds(_ criteria: SearchCriteria) -> String {
        var kinds: [String] = []
        if !criteria.keyword.isEmpty { kinds.append("k") }
        if !criteria.selectedGroupIds.isEmpty { kinds.append("g") }
        if !criteria.selectedTypes.isEmpty { kinds.append("t") }
        if !criteria.selectedAppIDs.isEmpty { kinds.append("a") }
        if criteria.selectedDateFilter != nil { kinds.append("d") }
        return kinds.isEmpty ? "-" : kinds.joined()
    }

    /// 搜索时按需触发未完成 OCR 图片的快速优先识别（Fast-path）
    private func triggerOnDemandOCRFallback(for criteria: SearchCriteria) {
        guard DeferredOCRCoordinator.shared.hasPendingItems else { return }
        onDemandOCRTask?.cancel()
        onDemandOCRTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let hasUpdated = await DeferredOCRCoordinator.shared.processOnDemandIfNeeded(keyword: criteria.keyword)
            guard !Task.isCancelled, hasUpdated else { return }
            if self.isInFilterMode, self.filterState.criteria.keyword == criteria.keyword {
                self.searchData(self.filterState.criteria, triggerOCR: false)
            }
        }
    }

    /// 判定条目是否匹配当前激活的筛选规则（无关键词检索时优先内存零开销核定，彻底省去一次 SQLite 往返）
    func modelMatchesActiveFilter(_ model: PasteboardModel, filter: Expression<Bool>, modelId: Int64) async -> Bool {
        let criteria = filterState.criteria
        if criteria.keyword.isEmpty {
            if !criteria.selectedGroupIds.isEmpty {
                if !criteria.selectedGroupIds.contains(model.group) { return false }
            } else if model.hidden {
                return false
            }
            if !criteria.selectedTypes.isEmpty, !criteria.selectedTypes.contains(model.type) {
                return false
            }
            if !criteria.selectedAppIDs.isEmpty {
                guard let appID = model.appID, criteria.selectedAppIDs.contains(appID) else { return false }
            }
            if let dateFilter = criteria.selectedDateFilter {
                let (start, end) = dateFilter.timestampRange()
                if model.timestamp < start { return false }
                if let end, model.timestamp >= end { return false }
            }
            return true
        }
        return await PasteReadStore.shared.getCount(filter: filter && Col.id == modelId) > 0
    }
}
