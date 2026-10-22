//
//  StorageAnalysisService.swift
//  Clipboard
//
//  存储健康与大项分析服务
//

import AppKit
import Combine
import Foundation
import SwiftUI

@MainActor
final class StorageAnalysisService: ObservableObject {
    static let shared = StorageAnalysisService()

    @Published private(set) var diskUsage: StorageDiskUsage?
    @Published private(set) var typeProportions: [StorageTypeProportion] = []
    @Published private(set) var topItems: [StorageItemSummary] = []
    @Published private(set) var quotaStatus: StorageQuotaStatus?
    @Published private(set) var isAnalyzing: Bool = false
    @Published private(set) var isVacuuming: Bool = false
    @Published private(set) var isEvicting: Bool = false

    private let sqlManager = PasteSQLManager.manager

    init() {}

    func refreshDiskUsage() async {
        let usage = await sqlManager.getStorageDiskUsage()
        let proportions = await sqlManager.getStorageTypeProportions()
        self.diskUsage = usage
        self.typeProportions = proportions
        await refreshQuotaStatus()
    }

    func refreshQuotaStatus() async {
        let usage = if let diskUsage {
            diskUsage
        } else {
            await sqlManager.getStorageDiskUsage()
        }
        let isEnabled = PasteUserDefaults.enableSoftQuota
        let quotaBytes = isEnabled ? PasteUserDefaults.softQuotaBytes : 0
        let policyRaw = PasteUserDefaults.softQuotaAgingPolicy
        let policy = SoftQuotaAgingPolicy(rawValue: policyRaw) ?? .threeMonths

        let (candidateCount, candidateBytes) = await sqlManager.getEvictionCandidates(policy: policy)

        self.quotaStatus = StorageQuotaStatus(
            currentBytes: usage.totalDiskBytes,
            quotaBytes: quotaBytes,
            candidateItemCount: candidateCount,
            candidateFreedBytes: candidateBytes
        )
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

    /// 执行智能建议的一键瘦身
    func applyRecommendedEviction() async throws -> Int64 {
        isEvicting = true
        defer { isEvicting = false }
        let policyRaw = PasteUserDefaults.softQuotaAgingPolicy
        let policy = SoftQuotaAgingPolicy(rawValue: policyRaw) ?? .threeMonths
        let freed = await sqlManager.performAutoEviction(policy: policy)
        await refreshDiskUsage()
        await PasteDataStore.main.resetDefaultList()
        let count = await sqlManager.getTotalCount()
        PasteDataStore.main.totalCount = count
        return freed
    }
}
