//
//  StorageAnalysisService.swift
//  Clipboard
//
//  存储空间深度分析与用户自主清理调度服务
//

import AppKit
import Combine
import Foundation
import SwiftUI

// MARK: - 存储分析协调服务

@MainActor
final class StorageAnalysisService: ObservableObject {
    static let shared = StorageAnalysisService()

    @Published private(set) var diskUsage: StorageDiskUsage?
    @Published private(set) var typeProportions: [StorageTypeProportion] = []
    @Published private(set) var topItems: [StorageItemSummary] = []
    @Published private(set) var isAnalyzing: Bool = false
    @Published private(set) var isVacuuming: Bool = false

    private let sqlManager = PasteSQLManager.manager

    init() {}

    func refreshDiskUsage() async {
        let usage = await sqlManager.getStorageDiskUsage()
        let proportions = await sqlManager.getStorageTypeProportions()
        self.diskUsage = usage
        self.typeProportions = proportions
    }

    func loadTopItems(limit: Int = 100, filter: StoragePresetFilter = .all) async {
        isAnalyzing = true
        defer { isAnalyzing = false }
        let items = await sqlManager.getTopStorageItems(limit: limit, filter: filter)
        self.topItems = items
    }

    func deleteItems(ids: [Int64]) async throws -> Int64 {
        let freed = await sqlManager.deleteStorageItems(ids: ids)
        // 刷新存储统计与主界面列表
        await refreshDiskUsage()
        await PasteDataStore.main.resetDefaultList()
        let count = await sqlManager.getTotalCount()
        PasteDataStore.main.totalCount = count
        return freed
    }

    func vacuumDatabase() async throws -> (beforeBytes: Int64, afterBytes: Int64) {
        isVacuuming = true
        defer { isVacuuming = false }
        let result = try await sqlManager.vacuumDatabase()
        await refreshDiskUsage()
        await PasteDataStore.main.resetDefaultList()
        let count = await sqlManager.getTotalCount()
        PasteDataStore.main.totalCount = count
        return result
    }
}
