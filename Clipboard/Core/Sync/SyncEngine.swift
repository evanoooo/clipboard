//
//  SyncEngine.swift
//  Clipboard
//
//  WebDAV 增量同步核心调度器：持有同步状态、凭据/密钥缓存，并编排增量同步主流程
//

import AppKit
import Combine
import CryptoKit
import Foundation
import SQLite

nonisolated enum SyncState: Sendable, Equatable {
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
            let timeText = date.formatted(date: .omitted, time: .standard)
            return "已同步 (\(timeText))"
        case let .failed(msg): return "同步失败: \(msg)"
        }
    }
}

// MARK: - 实时同步日志模型

nonisolated struct SyncLogItem: Identifiable, Sendable {
    let id: UUID
    let timestamp: String
    let message: String
    let isError: Bool

    init(message: String, isError: Bool = false) {
        self.id = UUID()
        self.timestamp = Date().formatted(date: .omitted, time: .standard)
        self.message = message
        self.isError = isError
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
    @Published private(set) var syncProgress: String?
    @Published private(set) var syncLogs: [SyncLogItem] = []

    var lastRemoteETag: String?
    var isDirty = false
    var isCancelled = false
    var dirtyGeneration: UInt64 = 0
    var activeSyncTask: Task<SyncState, Never>?
    var debounceTask: Task<Void, Never>?
    var periodicSyncTimer: Timer?
    var powerObservers: [NSObjectProtocol] = []

    // MARK: - 性能优化缓存（密钥派生与连接池复用）

    private var cachedMasterKey: SymmetricKey?
    private var cachedKeySignature: String?
    private var cachedClient: WebDAVClient?
    private var cachedClientSignature: String?
    private var hasValidatedDirectoryStructure = false
    /// 损坏条目黑名单（解密/反序列化失败的坏数据，避免增量同步无限重试循环下载）
    private var corruptItemIDs = Set<String>()

    var isOnlySyncPinned: Bool {
        if UserDefaults.standard.object(forKey: "sync_only_pinned") == nil {
            return true
        }
        return UserDefaults.standard.bool(forKey: "sync_only_pinned")
    }

    private init() {
        loadCachedSummary()
        setupPowerAndSleepObservers()
        updateSyncSchedule()
    }

    // MARK: - 跨文件状态写入封装

    func setFetchingSummary(_ value: Bool) {
        isFetchingSummary = value
    }

    func setRestoring(_ restoring: Bool, message: String?) {
        isRestoring = restoring
        restoreMessage = message
    }

    func setRestoreMessage(_ message: String?) {
        restoreMessage = message
    }

    func setProgress(_ value: String?) {
        syncProgress = value
    }

    func applySummary(_ summary: SyncSummary) {
        syncSummary = summary
        saveSummaryCache(summary)
    }

    func recordCorruptItem(id: String) {
        corruptItemIDs.insert(id)
    }

    // MARK: - 任务入口

    /// 外部启动后台同步任务的规范入口（绑定 Task 句柄以支持安全取消）
    func startSyncTask() {
        guard currentState != .syncing else { return }
        activeSyncTask = Task { @MainActor [weak self] in
            guard let self else { return .idle }
            return await self.triggerSync()
        }
    }

    /// 取消当前正在执行的同步任务
    func cancelSync() {
        guard currentState == .syncing else { return }
        isCancelled = true
        activeSyncTask?.cancel()
        activeSyncTask = nil
        currentState = .idle
        syncProgress = nil
        addLog("已手动取消当前同步任务")
    }

    func invalidateClientAndKeyCache() {
        cachedMasterKey = nil
        cachedKeySignature = nil
        cachedClient = nil
        cachedClientSignature = nil
        hasValidatedDirectoryStructure = false
        corruptItemIDs.removeAll()
    }

    func getCachedClient(serverURL: URL, username: String?, password: String?) -> WebDAVClient {
        let sig = "\(serverURL.absoluteString)|\(username ?? "")|\(password ?? "")"
        if let cachedClient, cachedClientSignature == sig {
            return cachedClient
        }
        let client = WebDAVClient(baseURL: serverURL, username: username, password: password)
        self.cachedClient = client
        self.cachedClientSignature = sig
        return client
    }

    func getCachedMasterKey(passphrase: String, salt: Data) throws -> SymmetricKey {
        let sig = "\(passphrase)|\(salt.base64EncodedString())"
        if let cachedMasterKey, cachedKeySignature == sig {
            return cachedMasterKey
        }
        let key = try SyncCryptoEngine.deriveKey(passphrase: passphrase, salt: salt)
        self.cachedMasterKey = key
        self.cachedKeySignature = sig
        return key
    }

    // MARK: - 日志记录

    func addLog(_ message: String, isError: Bool = false) {
        let item = SyncLogItem(message: message, isError: isError)
        // 性能极致优化：原子合批更新，避免同一操作触发多次 @Published 与双重数组内存拷贝
        if syncLogs.count >= 100 {
            var updated = syncLogs
            updated.removeFirst(updated.count - 99)
            updated.append(item)
            syncLogs = updated
        } else {
            syncLogs.append(item)
        }
        if isError {
            Log.sync.error("[Sync] \(message)")
        } else {
            Log.sync.info("[Sync] \(message)")
        }
    }

    func clearLogs() {
        syncLogs.removeAll()
    }

    // MARK: - 缓存与下载助手

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

    nonisolated static func downloadItemData(id: String, client: WebDAVClient) async -> Data? {
        let sharded = SyncIndex.shardedItemPath(for: id)
        do {
            return try await client.download(from: sharded)
        } catch WebDAVError.notFound {
            let legacy = SyncIndex.legacyItemPath(for: id)
            return try? await client.download(from: legacy)
        } catch {
            return nil
        }
    }

    // MARK: - 静态纯函数：Diff 计算矩阵 (供测试与引擎共享)

    static func calculateDiff(
        localItems: [SyncItemBlob],
        remoteIndex: SyncIndex,
        onlySyncPinned: Bool = false,
        pendingDeletions: Set<String> = []
    ) -> SyncDiffResult {
        SyncDiffEngine.calculateDiff(
            localItems: localItems,
            remoteIndex: remoteIndex,
            onlySyncPinned: onlySyncPinned,
            pendingDeletions: pendingDeletions
        )
    }

    // MARK: - 手动或定时触发增量同步

    @discardableResult
    func triggerSync() async -> SyncState {
        guard UserDefaults.standard.bool(forKey: "sync_enabled") else {
            let state: SyncState = .disabled
            currentState = state
            return state
        }
        guard currentState != .syncing else { return currentState }
        isCancelled = false
        let syncStartGeneration = self.dirtyGeneration
        currentState = .syncing
        syncProgress = "准备连接服务器..."
        addLog("====== 开始增量同步流程 ======")

        defer {
            syncProgress = nil
            activeSyncTask = nil
        }

        do {
            guard let creds = resolveCredentials() else {
                let state: SyncState = .failed(message: "同步配置或密码未完整设置")
                currentState = state
                addLog("同步配置或主密码未完整设置", isError: true)
                return state
            }

            if isCancelled || Task.isCancelled {
                currentState = .idle
                addLog("增量同步已取消")
                return .idle
            }

            let client = getCachedClient(
                serverURL: creds.serverURL,
                username: creds.username,
                password: creds.password
            )

            if !hasValidatedDirectoryStructure {
                syncProgress = "验证云端目录结构..."
                let (_, latency) = try await client.testConnection()
                addLog("服务器连通性正常，网络往返延迟: \(latency.formatted(.number.precision(.fractionLength(0)))) ms")
                try await client.makeDirectory(path: "ClipboardSync")
                try await client.makeDirectory(path: "ClipboardSync/items")
                hasValidatedDirectoryStructure = true
            }

            if isCancelled || Task.isCancelled {
                currentState = .idle
                addLog("增量同步已取消")
                return .idle
            }

            let masterKey: SymmetricKey
            do {
                masterKey = try await loadSaltAndMasterKey(
                    client: client,
                    passphrase: creds.passphrase,
                    createIfMissing: true
                )
            } catch {
                let msg = "读取云端安全元数据失败: \(error.localizedDescription)"
                addLog(msg, isError: true)
                let state: SyncState = .failed(message: msg)
                currentState = state
                return state
            }

            if isCancelled || Task.isCancelled {
                currentState = .idle
                addLog("增量同步已取消")
                return .idle
            }

            let indexPath = "ClipboardSync/index.json.enc"
            let currentETag = try? await client.getETag(path: indexPath)
            if !isDirty, let currentETag, let lastRemoteETag, currentETag == lastRemoteETag {
                let finishTime = Int64(Date().timeIntervalSince1970 * 1000)
                let state: SyncState = .success(lastSyncTime: finishTime)
                currentState = state
                addLog("ETag 一致且本地无脏数据，极速预检完成（0 传输开销）")
                return state
            }

            if isCancelled || Task.isCancelled {
                currentState = .idle
                addLog("增量同步已取消")
                return .idle
            }

            syncProgress = "获取云端索引清单..."
            var remoteIndex = SyncIndex()
            do {
                let encIndexData = try await client.download(from: indexPath)
                guard let rawIndexData = try? SyncCryptoEngine.decrypt(data: encIndexData, using: masterKey) else {
                    let msg = "云端索引已存在但解密失败，请检查同步主密码是否正确"
                    addLog(msg, isError: true)
                    let state: SyncState = .failed(message: msg)
                    currentState = state
                    return state
                }
                guard let decoded = try? JSONDecoder().decode(SyncIndex.self, from: rawIndexData) else {
                    let msg = "云端索引清单数据损坏或格式不兼容"
                    addLog(msg, isError: true)
                    let state: SyncState = .failed(message: msg)
                    currentState = state
                    return state
                }
                remoteIndex = decoded
                addLog("已成功解析云端索引: 现有记录 \(remoteIndex.entries.count) 条")
            } catch let error as WebDAVError {
                if case .notFound = error {
                    addLog("云端尚无索引文件，将初始化全新清单")
                } else {
                    let msg = "下载云端索引清单失败: \(error.localizedDescription)"
                    addLog(msg, isError: true)
                    let state: SyncState = .failed(message: msg)
                    currentState = state
                    return state
                }
            } catch {
                let msg = "下载云端索引清单失败: \(error.localizedDescription)"
                addLog(msg, isError: true)
                let state: SyncState = .failed(message: msg)
                currentState = state
                return state
            }

            if isCancelled || Task.isCancelled {
                currentState = .idle
                addLog("增量同步已取消")
                return .idle
            }

            syncProgress = "扫描本地数据库并比对差异..."
            let onlySyncPinned = self.isOnlySyncPinned
            let localBlobs = await SyncWorker.shared.fetchLocalBlobsForSync(onlySyncPinned: onlySyncPinned)

            if isCancelled || Task.isCancelled {
                currentState = .idle
                addLog("增量同步已取消")
                return .idle
            }

            addLog("本地 SQLite 扫描完成: 共有 \(localBlobs.count) 条待比对记录 (仅同步收藏: \(onlySyncPinned))")

            let pendingDeletions = SyncPendingDeletionsStore.shared.getAllDeletions()
            let diff = await SyncWorker.shared.calculateDiff(
                localItems: localBlobs,
                remoteIndex: remoteIndex,
                onlySyncPinned: onlySyncPinned,
                pendingDeletions: pendingDeletions,
                corruptItemIDs: corruptItemIDs
            )
            addLog(
                "Diff 计算完成: 待上传 \(diff.toUpload.count) 条, 待下载 \(diff.toDownload.count) 条, "
                    + "待清理本地 \(diff.toDeleteLocal.count) 条, 待清理远端 \(diff.toDeleteRemote.count) 条"
            )

            _ = try await downloadAndIngestBatches(
                ids: diff.toDownload,
                remoteEntries: remoteIndex.entries,
                client: client,
                masterKey: masterKey,
                progressVerb: "正在下载云端条目",
                logVerb: "下载进度",
                trackCorrupt: true
            )

            if isCancelled || Task.isCancelled {
                currentState = .idle
                addLog("增量同步已取消")
                return .idle
            }

            if !diff.toDeleteLocal.isEmpty {
                addLog("检测到远端已标记删除 \(diff.toDeleteLocal.count) 条记录，正在同步清理本地 SQLite...")
                await PasteDataStore.main.deleteSyncedBatch(uniqueIds: diff.toDeleteLocal)
            }

            if !diff.toDownload.isEmpty || !diff.toDeleteLocal.isEmpty {
                await PasteDataStore.main.reloadHistory()
            }

            if isCancelled || Task.isCancelled {
                currentState = .idle
                addLog("增量同步已取消")
                return .idle
            }

            try await uploadBatches(
                blobs: diff.toUpload,
                remoteIndex: &remoteIndex,
                client: client,
                masterKey: masterKey,
                indexPath: indexPath
            )

            if isCancelled || Task.isCancelled {
                currentState = .idle
                addLog("增量同步已取消")
                return .idle
            }

            for id in diff.toDeleteRemote {
                if isCancelled || Task.isCancelled { break }
                try? await client.delete(path: SyncIndex.shardedItemPath(for: id))
                try? await client.delete(path: SyncIndex.legacyItemPath(for: id))
                remoteIndex.entries[id] = SyncIndexEntry(
                    uniqueId: id,
                    updatedAt: Int64(Date().timeIntervalSince1970),
                    checksum: "",
                    isDeleted: true,
                    group: -1,
                    type: nil,
                    tag: nil,
                    size: 0
                )
            }

            if !diff.toDeleteRemote.isEmpty {
                SyncPendingDeletionsStore.shared.clear(uniqueIds: diff.toDeleteRemote)
            }

            let prunedCount = remoteIndex.pruneExpiredTombstones()
            if prunedCount > 0 {
                addLog("已自动修剪 30 天超期墓碑 \(prunedCount) 条，云端索引保持轻量")
            }

            let downloadedSet = Set(diff.toDownload)
            let localBlobMap = Dictionary(
                localBlobs.map { ($0.uniqueId, $0) },
                uniquingKeysWith: { first, _ in first }
            )
            for (id, var entry) in remoteIndex.entries where !entry.isDeleted && !downloadedSet.contains(id) {
                var modified = false
                if let local = localBlobMap[id] {
                    if entry.type == nil || entry.type?.isEmpty == true {
                        entry.type = local.pasteboardType
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

            syncProgress = "保存云端索引清单..."
            remoteIndex.lastModified = Int64(Date().timeIntervalSince1970 * 1000)
            let updatedIndexData = try JSONEncoder().encode(remoteIndex)
            let encUpdatedIndex = try SyncCryptoEngine.encrypt(data: updatedIndexData, using: masterKey)
            try await client.upload(data: encUpdatedIndex, to: indexPath)

            self.lastRemoteETag = try? await client.getETag(path: indexPath)
            if self.dirtyGeneration == syncStartGeneration {
                self.isDirty = false
            } else {
                self.isDirty = true
                self.markDirtyAndSchedule()
            }

            let summary = remoteIndex.generateSummary(chips: CategoryChipStore.shared.chips)
            applySummary(summary)

            let finishTime = Int64(Date().timeIntervalSince1970 * 1000)
            let state: SyncState = .success(lastSyncTime: finishTime)
            self.currentState = state
            addLog("====== 同步圆满成功 (云端总条目: \(summary.totalCount)) ======")
            return state
        } catch is CancellationError {
            let state: SyncState = .idle
            self.currentState = state
            addLog("增量同步已取消")
            return state
        } catch {
            let state: SyncState = .failed(message: error.localizedDescription)
            self.currentState = state
            addLog("同步失败: \(error.localizedDescription)", isError: true)
            return state
        }
    }
}
