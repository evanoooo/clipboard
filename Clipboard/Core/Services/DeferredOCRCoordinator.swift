//
//  DeferredOCRCoordinator.swift
//  Clipboard
//
//  平峰填谷的延迟批量 OCR 协调器与搜索按需实时唤醒管理器
//

import AppKit
import Combine
import Foundation

@MainActor
final class DeferredOCRCoordinator {
    static let shared = DeferredOCRCoordinator()

    /// 待识别图片的 ID 集合
    private var pendingIDs = Set<Int64>()
    /// 正在执行 OCR 的 ID 集合（防重复调度）
    private var inFlightIDs = Set<Int64>()

    /// 静默批处理长缓冲防抖任务
    private var debounceTimer: Task<Void, Never>?

    /// 默认长缓冲时间（2 分钟平峰填谷）
    private let idleBufferDuration: Duration = .seconds(120)

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
    }

    var hasPendingItems: Bool {
        !pendingIDs.isEmpty
    }

    // MARK: - 模式 A：平峰填谷长缓冲静默批处理

    private func scheduleIdleProcessing() {
        debounceTimer?.cancel()
        debounceTimer = Task { [weak self] in
            try? await Task.sleep(for: self?.idleBufferDuration ?? .seconds(120))
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

        // 2. 若系统处于低电量模式，推迟执行
        if SystemEnergyMonitor.shared.isLowPowerMode {
            schedulePostponed(duration: .seconds(60))
            return
        }

        await processQueue(maxBatchCount: 10, priority: .utility)
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
        let successCount = await processQueue(maxBatchCount: batchLimit, priority: .userInitiated)
        return successCount > 0
    }

    // MARK: - 批处理调度核心

    @discardableResult
    private func processQueue(maxBatchCount: Int, priority: TaskPriority) async -> Int {
        let candidates = Array(pendingIDs.subtracting(inFlightIDs).prefix(maxBatchCount))
        guard !candidates.isEmpty else { return 0 }

        for id in candidates {
            inFlightIDs.insert(id)
        }

        var processedCount = 0

        for id in candidates {
            guard !Task.isCancelled else { break }
            let success = await processSingleItem(id: id, priority: priority)
            inFlightIDs.remove(id)
            if success {
                pendingIDs.remove(id)
                processedCount += 1
            }
            await Task.yield()
        }

        if !pendingIDs.isEmpty {
            scheduleIdleProcessing()
        }

        return processedCount
    }

    private func processSingleItem(id: Int64, priority: TaskPriority) async -> Bool {
        // 从磁盘独立只读点查图片的原始 Data，绝不在主线程/内存大列表持有大图
        guard let data = await Task.detached(priority: priority, operation: {
            PasteDataPointReader.loadData(id: id, uniqueId: "")
        }).value, !data.isEmpty else {
            return true // 无效数据移出队列
        }

        let rawText = await OCRViewService.shared.recognizeText(from: data)
        guard !rawText.isEmpty else {
            // 图片无文字，移出待办队列避免无意义重试
            return true
        }

        let searchText = PasteboardModel.normalizeSearchText(rawText)
        let updated = await PasteSQLManager.manager.updateSearchText(id: id, searchText: searchText)
        if updated {
            // 同步更新内存中的模型搜索文本（如果该卡片正在展示列表中）
            if let model = PasteDataStore.main.dataList.value.first(where: { $0.id == id }) {
                model.updateSearchText(val: searchText)
            }
            SyncEngine.shared.markDirtyAndSchedule()
        }
        return true
    }
}
