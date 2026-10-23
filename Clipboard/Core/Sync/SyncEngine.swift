//
//  SyncEngine.swift
//  Clipboard
//
//  WebDAV 增量同步调度引擎：Diff 比对、LWW 冲突裁决、15s 防抖与并发传输管线
//

import Combine
import CryptoKit
import Foundation
import SQLite

enum SyncState: Sendable, Equatable {
    case disabled
    case idle
    case syncing
    case success(lastSyncTime: Int64)
    case failed(message: String)

    var displayText: String {
        switch self {
        case .disabled: return "未启用"
        case .idle: return "就绪"
        case .syncing: return "正在同步..."
        case let .success(time):
            let date = Date(timeIntervalSince1970: Double(time) / 1000.0)
            let formatter = DateFormatter()
            formatter.dateFormat = "HH:mm:ss"
            return "已同步 (\(formatter.string(from: date)))"
        case let .failed(msg): return "同步失败: \(msg)"
        }
    }
}

@MainActor
final class SyncEngine: ObservableObject {
    static let shared = SyncEngine()

    @Published private(set) var currentState: SyncState = .idle
    @Published private(set) var syncSummary: SyncSummary?
    @Published private(set) var isRestoring: Bool = false
    @Published private(set) var restoreMessage: String?
    @Published private(set) var isFetchingSummary: Bool = false

    private var lastRemoteETag: String?
    private var isDirty = false
    private var debounceTask: Task<Void, Never>?

    private init() {
        loadCachedSummary()
    }

    // MARK: - 缓存摘要

    private func loadCachedSummary() {
        if let data = UserDefaults.standard.data(forKey: "sync_summary_cache"),
           let summary = try? JSONDecoder().decode(SyncSummary.self, from: data) {
            self.syncSummary = summary
        }
    }

    private func saveSummaryCache(_ summary: SyncSummary) {
        if let data = try? JSONEncoder().encode(summary) {
            UserDefaults.standard.set(data, forKey: "sync_summary_cache")
        }
    }

    // MARK: - 静态纯函数：Diff 计算矩阵 (供测试与引擎共享)

    static func calculateDiff(
        localItems: [SyncItemBlob],
        remoteIndex: SyncIndex,
        onlySyncPinned: Bool = false
    ) -> SyncDiffResult {
        SyncDiffEngine.calculateDiff(localItems: localItems, remoteIndex: remoteIndex, onlySyncPinned: onlySyncPinned)
    }

    // MARK: - 从 SQLite 全量加载待同步数据（彻底脱离 UI 分页 50 条限制）

    private func fetchLocalBlobsForSync(onlySyncPinned: Bool) async -> [SyncItemBlob] {
        let filter: Expression<Bool> = onlySyncPinned
            ? (Col.group >= 0 && Col.hidden == 0)
            : (Col.hidden == 0)

        let sel: [Expressible] = [
            Col.id, Col.uniqueId, Col.type, Col.data, Col.timestamp,
            Col.showData, Col.group, Col.tag, Col.alias
        ]

        // 若仅同步收藏和分组，查询全部分组（通常数百条）；若同步全量流水，设定 5000 条上限
        let rows = await PasteReadStore.shared.search(
            filter: filter,
            select: sel,
            limit: onlySyncPinned ? nil : 5000
        )

        return rows.compactMap { row in
            guard let uniqueId = try? row.get(Col.uniqueId),
                  let timestamp = try? row.get(Col.timestamp) else {
                return nil
            }
            let rawType = (try? row.get(Col.type)) ?? ""
            let id = try? row.get(Col.id)
            var payloadData = try? row.get(Col.data)
            if payloadData == nil, let id {
                payloadData = PasteDataPointReader.loadData(id: id, uniqueId: uniqueId)
            }
            let showData = try? row.get(Col.showData)
            let group = (try? row.get(Col.group)) ?? -1
            let tag = (try? row.get(Col.tag)) ?? ""
            let alias = (try? row.get(Col.alias)) ?? ""

            return SyncItemBlob(
                uniqueId: uniqueId,
                pasteboardType: rawType,
                payloadData: payloadData,
                showData: showData,
                timestamp: timestamp,
                group: group,
                tag: tag,
                alias: alias,
                sourceAppName: nil
            )
        }
    }

    // MARK: - 防抖调度 (Debounce 15s)

    func markDirtyAndSchedule() {
        guard UserDefaults.standard.bool(forKey: "sync_enabled") else { return }
        isDirty = true
        debounceTask?.cancel()
        debounceTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 15_000_000_000) // 15秒防抖
            guard !Task.isCancelled else { return }
            await self?.triggerSync()
        }
    }

    // MARK: - 仅刷新云端资产看板摘要

    @discardableResult
    func fetchCloudSummary() async -> SyncSummary? {
        guard UserDefaults.standard.bool(forKey: "sync_enabled") else { return nil }
        guard !isFetchingSummary else { return syncSummary }
        isFetchingSummary = true
        defer { isFetchingSummary = false }

        do {
            guard let serverURLString = UserDefaults.standard.string(forKey: "sync_webdav_url"),
                  let serverURL = URL(string: serverURLString),
                  let username = UserDefaults.standard.string(forKey: "sync_webdav_username"),
                  let password = SyncKeychainManager.shared.loadWebDAVPassword(),
                  let passphrase = SyncKeychainManager.shared.loadSyncPassphrase(),
                  !passphrase.isEmpty else {
                return nil
            }

            let client = WebDAVClient(baseURL: serverURL, username: username, password: password)
            let saltPath = "ClipboardSync/vault.meta.enc"
            guard let salt = try? await client.download(from: saltPath) else { return nil }
            let masterKey = try SyncCryptoEngine.deriveKey(passphrase: passphrase, salt: salt)

            let indexPath = "ClipboardSync/index.json.enc"
            guard let encIndexData = try? await client.download(from: indexPath),
                  let rawIndexData = try? SyncCryptoEngine.decrypt(data: encIndexData, using: masterKey),
                  let remoteIndex = try? JSONDecoder().decode(SyncIndex.self, from: rawIndexData) else {
                return nil
            }

            let summary = remoteIndex.generateSummary(chips: CategoryChipStore.shared.chips)
            self.syncSummary = summary
            saveSummaryCache(summary)
            return summary
        } catch {
            return nil
        }
    }

    // MARK: - 从云端还原

    /// 从云端拉取还原数据
    /// - Parameter overwriteLocal: 若为 false，进行智能安全合并（仅补充本地缺失或陈旧条目，保留本地一切新增）；若为 true，先清空本地，完全由云端镜像覆盖。
    @discardableResult
    func restoreFromCloud(overwriteLocal: Bool = false) async -> (success: Bool, message: String) {
        guard UserDefaults.standard.bool(forKey: "sync_enabled") else {
            return (false, "请先启用云端同步")
        }
        guard !isRestoring, currentState != .syncing else {
            return (false, "同步或还原正在进行中")
        }

        isRestoring = true
        restoreMessage = nil
        defer { isRestoring = false }

        do {
            guard let serverURLString = UserDefaults.standard.string(forKey: "sync_webdav_url"),
                  let serverURL = URL(string: serverURLString),
                  let username = UserDefaults.standard.string(forKey: "sync_webdav_username"),
                  let password = SyncKeychainManager.shared.loadWebDAVPassword(),
                  let passphrase = SyncKeychainManager.shared.loadSyncPassphrase(),
                  !passphrase.isEmpty else {
                let msg = "WebDAV 账号或同步密码未配置完整"
                restoreMessage = msg
                return (false, msg)
            }

            let client = WebDAVClient(baseURL: serverURL, username: username, password: password)

            // 1. 获取 salt 与派生主密钥
            let saltPath = "ClipboardSync/vault.meta.enc"
            guard let salt = try? await client.download(from: saltPath) else {
                let msg = "未找到云端密钥元数据，云端可能尚未进行过备份"
                restoreMessage = msg
                return (false, msg)
            }
            let masterKey = try SyncCryptoEngine.deriveKey(passphrase: passphrase, salt: salt)

            // 2. 下载并解密云端索引
            let indexPath = "ClipboardSync/index.json.enc"
            guard let encIndexData = try? await client.download(from: indexPath),
                  let rawIndexData = try? SyncCryptoEngine.decrypt(data: encIndexData, using: masterKey),
                  let remoteIndex = try? JSONDecoder().decode(SyncIndex.self, from: rawIndexData) else {
                let msg = "读取或解密云端索引失败，请检查同步密码是否正确"
                restoreMessage = msg
                return (false, msg)
            }

            let activeEntries = remoteIndex.entries.values.filter { !$0.isDeleted }

            // 3. 计算需要拉取的条目 ID
            var toDownloadIds: [String] = []

            if overwriteLocal {
                // 完全覆盖模式：清空本地历史
                _ = try await PasteSQLManager.manager.clearHistory(includePinnedAndGrouped: true)
                toDownloadIds = activeEntries.map(\.uniqueId)
            } else {
                // 智能安全合并模式：查询 SQLite 数据库全量条目比对，保留本地所有已有和新增！
                let localRows = await PasteReadStore.shared.search(
                    select: [Col.uniqueId, Col.timestamp],
                    limit: nil
                )
                var localMap: [String: Int64] = [:]
                for r in localRows {
                    if let uid = try? r.get(Col.uniqueId), let ts = try? r.get(Col.timestamp) {
                        localMap[uid] = ts
                    }
                }

                for entry in activeEntries {
                    if let localTimestamp = localMap[entry.uniqueId] {
                        if entry.updatedAt > localTimestamp {
                            toDownloadIds.append(entry.uniqueId)
                        }
                    } else {
                        toDownloadIds.append(entry.uniqueId)
                    }
                }
            }

            // 4. 并发拉取并写入本地数据库
            var restoredCount = 0
            try await withThrowingTaskGroup(of: PasteboardModel?.self) { group in
                for id in toDownloadIds {
                    group.addTask {
                        guard let encData = try? await client.download(from: "ClipboardSync/items/\(id).enc"),
                              let rawData = try? SyncCryptoEngine.decrypt(data: encData, using: masterKey),
                              let blob = try? JSONDecoder().decode(SyncItemBlob.self, from: rawData) else {
                            return nil
                        }
                        return await MainActor.run { blob.toPasteboardModel() }
                    }
                }
                for try await model in group {
                    if let model {
                        await PasteDataStore.main.insertModel(model)
                        restoredCount += 1
                    }
                }
            }

            // 5. 刷新历史列表与更新资产概览
            await PasteDataStore.main.reloadHistory()
            let summary = remoteIndex.generateSummary(chips: CategoryChipStore.shared.chips)
            self.syncSummary = summary
            saveSummaryCache(summary)

            let msg = overwriteLocal
                ? "完全覆盖完成：已从云端拉取 \(restoredCount) 条记录并完全覆盖本地。"
                : "智能合并完成：已拉取恢复 \(restoredCount) 条云端记录，本地现有数据均已完好保留。"
            self.restoreMessage = msg
            return (true, msg)

        } catch {
            let errorMsg = "还原失败: \(error.localizedDescription)"
            self.restoreMessage = errorMsg
            return (false, errorMsg)
        }
    }

    // MARK: - 手动或定时触发同步

    @discardableResult
    func triggerSync() async -> SyncState {
        guard UserDefaults.standard.bool(forKey: "sync_enabled") else {
            let state: SyncState = .disabled
            currentState = state
            return state
        }
        guard currentState != .syncing else { return currentState }
        currentState = .syncing

        do {
            // 1. 检查凭据配置
            guard let serverURLString = UserDefaults.standard.string(forKey: "sync_webdav_url"),
                  let serverURL = URL(string: serverURLString),
                  let username = UserDefaults.standard.string(forKey: "sync_webdav_username"),
                  let password = SyncKeychainManager.shared.loadWebDAVPassword(),
                  let passphrase = SyncKeychainManager.shared.loadSyncPassphrase(),
                  !passphrase.isEmpty else {
                let state: SyncState = .failed(message: "同步配置或密码未完整设置")
                currentState = state
                return state
            }

            let client = WebDAVClient(baseURL: serverURL, username: username, password: password)

            // 2. 确保远端同步目录存在
            try await client.makeDirectory(path: "ClipboardSync")
            try await client.makeDirectory(path: "ClipboardSync/items")

            // 3. 读取或生成加密 Salt 与派生主密钥
            let saltPath = "ClipboardSync/vault.meta.enc"
            var salt: Data
            if let existingSaltEnc = try? await client.download(from: saltPath) {
                salt = existingSaltEnc
            } else {
                salt = SyncCryptoEngine.generateSalt()
                try? await client.upload(data: salt, to: saltPath)
            }

            let masterKey = try SyncCryptoEngine.deriveKey(passphrase: passphrase, salt: salt)

            // 4. ETag 极速预检 (若远端索引未变且本地无新脏数据，百毫秒内退出)
            let indexPath = "ClipboardSync/index.json.enc"
            let currentETag = try? await client.getETag(path: indexPath)
            if !isDirty, let currentETag, let lastRemoteETag, currentETag == lastRemoteETag {
                let state: SyncState = .success(lastSyncTime: Int64(Date().timeIntervalSince1970 * 1000))
                currentState = state
                return state
            }

            // 5. 下载远端索引 (若尚无则初始化空白索引)
            var remoteIndex = SyncIndex()
            if let encIndexData = try? await client.download(from: indexPath) {
                if let rawIndexData = try? SyncCryptoEngine.decrypt(data: encIndexData, using: masterKey),
                   let decoded = try? JSONDecoder().decode(SyncIndex.self, from: rawIndexData) {
                    remoteIndex = decoded
                }
            }

            // 6. 从 SQLite 数据库全量收集本地数据并执行 Diff
            let onlySyncPinned = UserDefaults.standard.bool(forKey: "sync_only_pinned")
            let localBlobs = await fetchLocalBlobsForSync(onlySyncPinned: onlySyncPinned)

            let diff = Self.calculateDiff(localItems: localBlobs, remoteIndex: remoteIndex, onlySyncPinned: onlySyncPinned)

            // 7. 并发传输管线：下载需拉取条目
            try await withThrowingTaskGroup(of: PasteboardModel?.self) { group in
                for id in diff.toDownload {
                    group.addTask {
                        guard let encData = try? await client.download(from: "ClipboardSync/items/\(id).enc"),
                              let rawData = try? SyncCryptoEngine.decrypt(data: encData, using: masterKey),
                              let blob = try? JSONDecoder().decode(SyncItemBlob.self, from: rawData) else {
                            return nil
                        }
                        return await MainActor.run { blob.toPasteboardModel() }
                    }
                }
                for try await model in group {
                    if let model {
                        await PasteDataStore.main.insertModel(model)
                    }
                }
            }

            // 8. 并发传输管线：上传本地条目
            try await withThrowingTaskGroup(of: (String, SyncIndexEntry)?.self) { group in
                for blob in diff.toUpload {
                    group.addTask {
                        guard let rawData = try? JSONEncoder().encode(blob),
                              let encData = try? SyncCryptoEngine.encrypt(data: rawData, using: masterKey) else {
                            return nil
                        }
                        try await client.upload(data: encData, to: "ClipboardSync/items/\(blob.uniqueId).enc")
                        let checksum = SyncCryptoEngine.checksum(for: blob.payloadData ?? Data())
                        let estimatedSize = (blob.payloadData?.count ?? 0) + (blob.showData?.count ?? 0)
                        let entry = SyncIndexEntry(
                            uniqueId: blob.uniqueId,
                            updatedAt: blob.timestamp,
                            checksum: checksum,
                            isDeleted: false,
                            group: blob.group,
                            type: blob.pasteboardType,
                            tag: blob.tag,
                            size: estimatedSize
                        )
                        return (blob.uniqueId, entry)
                    }
                }
                for try await result in group {
                    if let (id, entry) = result {
                        remoteIndex.entries[id] = entry
                    }
                }
            }

            // 9. 远端删除实体文件并写入墓碑
            for id in diff.toDeleteRemote {
                try? await client.delete(path: "ClipboardSync/items/\(id).enc")
                remoteIndex.entries[id] = SyncIndexEntry(
                    uniqueId: id,
                    updatedAt: Int64(Date().timeIntervalSince1970 * 1000),
                    checksum: "",
                    isDeleted: true,
                    group: -1,
                    type: nil,
                    tag: nil,
                    size: 0
                )
            }

            // 10. 智能元数据回填：若远端索引某些活跃条目缺失 type 或 size，利用本地匹配补全
            let localBlobMap = Dictionary(localBlobs.map { ($0.uniqueId, $0) }, uniquingKeysWith: { first, _ in first })
            for (id, var entry) in remoteIndex.entries where !entry.isDeleted {
                var modified = false
                if let local = localBlobMap[id] {
                    if entry.type == nil || entry.type?.isEmpty == true {
                        entry.type = local.pasteboardType
                        modified = true
                    }
                    if entry.size == nil || entry.size == 0 {
                        entry.size = (local.payloadData?.count ?? 0) + (local.showData?.count ?? 0)
                        modified = true
                    }
                    if entry.group != local.group {
                        entry.group = local.group
                        modified = true
                    }
                }
                if modified {
                    remoteIndex.entries[id] = entry
                }
            }

            // 11. 加密上传最新索引清单并更新状态与资产看板
            remoteIndex.lastModified = Int64(Date().timeIntervalSince1970 * 1000)
            let updatedIndexData = try JSONEncoder().encode(remoteIndex)
            let encUpdatedIndex = try SyncCryptoEngine.encrypt(data: updatedIndexData, using: masterKey)
            try await client.upload(data: encUpdatedIndex, to: indexPath)

            self.lastRemoteETag = try? await client.getETag(path: indexPath)
            self.isDirty = false

            // 统计并缓存资产看板
            let summary = remoteIndex.generateSummary(chips: CategoryChipStore.shared.chips)
            self.syncSummary = summary
            saveSummaryCache(summary)

            let finishTime = Int64(Date().timeIntervalSince1970 * 1000)
            let state: SyncState = .success(lastSyncTime: finishTime)
            self.currentState = state
            return state

        } catch {
            let state: SyncState = .failed(message: error.localizedDescription)
            self.currentState = state
            return state
        }
    }
}
