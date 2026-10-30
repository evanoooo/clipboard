//
//  DeferredOCRCoordinator.swift
//  Clipboard
//
//  平峰填谷的延迟批量 OCR 协调器与搜索按需实时唤醒管理器
//

import AppKit
import Combine
import Foundation
import SQLite

@MainActor
final class DeferredOCRCoordinator {
    static let shared = DeferredOCRCoordinator()

    /// 单项处理结果状态
    private enum SingleProcessResult {
        case textRecognized
        case emptyOrSkipped
    }

    /// 待识别图片的 ID 集合
    private var pendingIDs = Set<Int64>()
    /// 正在执行 OCR 的 ID 集合（防重复调度）
    private var inFlightIDs = Set<Int64>()

    /// 静默批处理长缓冲防抖任务
    private var debounceTimer: Task<Void, Never>?

    /// 基于 uniqueId 的 OCR 识别结果内存轻量缓存（内容级去重，秒级复用，上限 100）
    private var ocrTextCache = [String: String]()

    /// 动态平峰填谷缓冲时间（能耗/温度高时 120 秒，正常供电时 45 秒）
    private var currentIdleBufferDuration: Duration {
        if SystemEnergyMonitor.shared.isLowPowerMode || SystemEnergyMonitor.shared.isThermalThrottled {
            return .seconds(120)
        }
        return .seconds(45)
    }

    private init() {}

    /// 待识别图片的 ID 集合快照（用于批量删除比对）
    var pendingSnapshot: Set<Int64> {
        pendingIDs
    }

    /// 新图片入库后登记待识别队列，并开启/重置长缓冲计时器
    func enqueue(id: Int64) {
        pendingIDs.insert(id)
        scheduleIdleProcessing()
    }

    /// 移除已删除或已清空的记录 ID
    func remove(id: Int64) {
        pendingIDs.remove(id)
        inFlightIDs.remove(id)
    }

    /// 批量移除已删除的记录 ID
    func remove(ids: any Sequence<Int64>) {
        for id in ids {
            pendingIDs.remove(id)
            inFlightIDs.remove(id)
        }
    }

    func clear() {
        debounceTimer?.cancel()
        debounceTimer = nil
        pendingIDs.removeAll()
        inFlightIDs.removeAll()
        ocrTextCache.removeAll(keepingCapacity: true)
    }

    var hasPendingItems: Bool {
        !pendingIDs.isEmpty
    }

    // MARK: - 冷启动兜底补漏

    /// 在应用启动后闲置期低优先级扫描近期待识别图片，防止前次异常退出导致漏跑
    func bootstrapPendingTasks() {
        Task(priority: .utility) { [weak self] in
            // 等待应用就绪，推迟 10 秒后执行冷启动补漏扫描
            try? await Task.sleep(for: .seconds(10))
            guard !Task.isCancelled, let self else { return }

            let rows = await PasteReadStore.shared.search(
                filter: ((Col.tag ?? "") == "image" || Col.type == "public.png" || Col.type == "public.tiff") && Col.searchText == "",
                select: [Col.id],
                order: [Col.id.desc],
                limit: 20
            )
            guard !rows.isEmpty else { return }

            let ids = rows.compactMap { try? $0.get(Col.id) }
            await MainActor.run {
                for id in ids {
                    self.pendingIDs.insert(id)
                }
                if !self.pendingIDs.isEmpty {
                    self.scheduleIdleProcessing()
                }
            }
        }
    }

    // MARK: - 模式 A：平峰填谷长缓冲静默批处理

    private func scheduleIdleProcessing() {
        debounceTimer?.cancel()
        debounceTimer = Task { [weak self] in
            try? await Task.sleep(for: self?.currentIdleBufferDuration ?? .seconds(45))
            guard !Task.isCancelled, let self else { return }
            await self.performIdleBatchOCR()
        }
    }

    private func performIdleBatchOCR() async {
        // 1. 若当前剪贴板窗口可见（用户正在交互），不抢占算力，推迟 30 秒
        if WindowManager.shared.isVisible {
            schedulePostponed(duration: .seconds(30))
            return
        }

        // 2. 若系统处于低电量模式，执行超轻量批次（2 张）以最低优先级后台消化，避免无限推迟空转
        if SystemEnergyMonitor.shared.isLowPowerMode {
            await processQueue(maxBatchCount: 2, priority: .background)
            return
        }

        await processQueue(maxBatchCount: 4, priority: .utility)
    }

    private func schedulePostponed(duration: Duration) {
        debounceTimer?.cancel()
        debounceTimer = Task { [weak self] in
            try? await Task.sleep(for: duration)
            guard !Task.isCancelled, let self else { return }
            await self.performIdleBatchOCR()
        }
    }

    // MARK: - 模式 B：搜索按需优先唤醒（Fast-path 插队执行）

    /// 当用户输入搜索关键字时，若队列中有待识别图片，立即优先在后台唤醒识别（限制最大 5 张，防前台卡顿）
    func processOnDemandIfNeeded(keyword: String) async -> Bool {
        guard !pendingIDs.isEmpty else { return false }
        let trimmed = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }

        let batchLimit = min(pendingIDs.count, 5)
        let (_, validTextCount) = await processQueue(maxBatchCount: batchLimit, priority: .userInitiated)
        return validTextCount > 0
    }

    // MARK: - 批处理调度核心

    @discardableResult
    private func processQueue(maxBatchCount: Int, priority: TaskPriority) async -> (processedCount: Int, validTextCount: Int) {
        let candidates = Array(pendingIDs.subtracting(inFlightIDs).prefix(maxBatchCount))
        guard !candidates.isEmpty else { return (0, 0) }

        for id in candidates {
            inFlightIDs.insert(id)
        }
        defer {
            // 确保任务取消中断或异常退出时，未触达的 candidate ID 得到安全释放，杜绝状态滞留
            for id in candidates {
                inFlightIDs.remove(id)
            }
        }

        var processedCount = 0
        var validTextCount = 0

        for id in candidates {
            guard !Task.isCancelled else { break }
            let result = await processSingleItem(id: id, priority: priority)
            inFlightIDs.remove(id)
            pendingIDs.remove(id)
            processedCount += 1
            if result == .textRecognized {
                validTextCount += 1
            }
            await Task.yield()
        }

        if !pendingIDs.isEmpty {
            scheduleIdleProcessing()
        }

        return (processedCount, validTextCount)
    }

    private func processSingleItem(id: Int64, priority: TaskPriority) async -> SingleProcessResult {
        // 1. 前置内存检查：若内存展示大列表中该卡片已有文本（非空），立即出队跳过
        if let memoryModel = await MainActor.run(body: {
            PasteDataStore.main.dataList.value.first(where: { $0.id == id })
        }), !memoryModel.searchText.isEmpty {
            return .emptyOrSkipped
        }

        // 2. 独立只读原子单点点查（一次性获取 searchText, uniqueId，若未识别再取 data）
        guard let target = await Task.detached(priority: priority, operation: {
            PasteDataPointReader.loadOCRTarget(id: id)
        }).value else {
            return .emptyOrSkipped // 记录已被删除或不存在
        }

        // 3. 数据库已有识别结果（真实文字或无字哨兵标记），直接出队跳过
        if !target.searchText.isEmpty {
            return .emptyOrSkipped
        }

        // 4. 检查基于 uniqueId 的内存轻量 OCR 缓存（内容级去重）
        let rawText: String
        if let cached = ocrTextCache[target.uniqueId] {
            rawText = cached
        } else {
            guard let data = target.data, !data.isEmpty else {
                let marker = PasteboardModel.emptyOCRMarker
                _ = await PasteSQLManager.manager.updateSearchText(id: id, searchText: marker)
                if let model = PasteDataStore.main.dataList.value.first(where: { $0.id == id }) {
                    model.updateSearchText(val: marker)
                }
                return .emptyOrSkipped
            }
            rawText = await OCRViewService.shared.recognizeText(from: data)
            if ocrTextCache.count >= 100 {
                ocrTextCache.removeAll(keepingCapacity: true)
            }
            ocrTextCache[target.uniqueId] = rawText
        }

        // 5. 若识别结果为空，写入无文字哨兵占位符 emptyOCRMarker，杜绝重复二次识别
        let isTextFound = !rawText.isEmpty
        let searchText = isTextFound
            ? PasteboardModel.normalizeSearchText(rawText)
            : PasteboardModel.emptyOCRMarker

        let updated = await PasteSQLManager.manager.updateSearchText(id: id, searchText: searchText)
        if updated {
            if let model = PasteDataStore.main.dataList.value.first(where: { $0.id == id }) {
                model.updateSearchText(val: searchText)
            }
            // 仅在真实识别出有效文字时才触发同步与索引脏标记
            if isTextFound {
                SyncEngine.shared.markDirtyAndSchedule()
            }
        }
        return isTextFound ? .textRecognized : .emptyOrSkipped
    }
}
