//
//  SyncEngine.swift
//  Clipboard
//
//  WebDAV 增量同步调度引擎：Diff 比对、LWW 冲突裁决、动态能耗感知防抖与受控滑动窗口并发流水线
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
            let formatter = DateFormatter()
            formatter.dateFormat = "HH:mm:ss"
            return "已同步 (\(formatter.string(from: date)))"
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
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        self.timestamp = formatter.string(from: Date())
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

    private var lastRemoteETag: String?
    private var isDirty = false
    private var isCancelled = false
    private var dirtyGeneration: UInt64 = 0
    private var activeSyncTask: Task<SyncState, Never>?
    private var debounceTask: Task<Void, Never>?
    private var powerObservers: [NSObjectProtocol] = []

    var isOnlySyncPinned: Bool {
        if UserDefaults.standard.object(forKey: "sync_only_pinned") == nil {
            return true
        }
        return UserDefaults.standard.bool(forKey: "sync_only_pinned")
    }

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

    // MARK: - 性能优化缓存（密钥派生与连接池复用）

    private var cachedMasterKey: SymmetricKey?
    private var cachedKeySignature: String?
    private var cachedClient: WebDAVClient?
    private var cachedClientSignature: String?
    private var hasValidatedDirectoryStructure = false

    func invalidateClientAndKeyCache() {
        cachedMasterKey = nil
        cachedKeySignature = nil
        cachedClient = nil
        cachedClientSignature = nil
        hasValidatedDirectoryStructure = false
    }

    private func getCachedClient(serverURL: URL, username: String?, password: String?) -> WebDAVClient {
        let sig = "\(serverURL.absoluteString)|\(username ?? "")|\(password ?? "")"
        if let cachedClient, cachedClientSignature == sig {
            return cachedClient
        }
        let client = WebDAVClient(baseURL: serverURL, username: username, password: password)
        self.cachedClient = client
        self.cachedClientSignature = sig
        return client
    }

    private func getCachedMasterKey(passphrase: String, salt: Data) throws -> SymmetricKey {
        let sig = "\(passphrase)|\(salt.base64EncodedString())"
        if let cachedMasterKey, cachedKeySignature == sig {
            return cachedMasterKey
        }
        let key = try SyncCryptoEngine.deriveKey(passphrase: passphrase, salt: salt)
        self.cachedMasterKey = key
        self.cachedKeySignature = sig
        return key
    }

    private init() {
        loadCachedSummary()
        setupPowerAndSleepObservers()
    }

    // MARK: - 系统功耗与睡眠感知生命周期

    private func setupPowerAndSleepObservers() {
        let center = NSWorkspace.shared.notificationCenter

        // 系统即将休眠：优雅中断正在进行的同步传输，防止在休眠中挂起导致唤醒后超时
        let obsSleep = center.addObserver(
            forName: NSWorkspace.willSleepNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if self.currentState == .syncing {
                    self.addLog("系统即将进入休眠，优雅中止后台同步任务")
                    self.cancelSync()
                }
            }
        }

        // 系统唤醒恢复：延迟 5 秒待 Wi-Fi 重连稳定后，如有脏数据自动触发增量同步
        let obsWake = center.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor [weak self] in
                guard let self else { return }
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                if UserDefaults.standard.bool(forKey: "sync_enabled"), self.isDirty {
                    self.addLog("系统唤醒网络已恢复，自动执行增量同步")
                    self.startSyncTask()
                }
            }
        }

        powerObservers = [obsSleep, obsWake]
    }

    // MARK: - 日志记录

    func addLog(_ message: String, isError: Bool = false) {
        let item = SyncLogItem(message: message, isError: isError)
        syncLogs.append(item)
        if syncLogs.count > 100 {
            syncLogs.removeFirst(syncLogs.count - 100)
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

    // MARK: - 缓存概要

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

    // MARK: - 从 SQLite 全量加载待同步数据（彻底脱离 UI 分页 50 条限制）

    private func fetchLocalBlobsForSync(onlySyncPinned: Bool) async -> [SyncItemBlob] {
        let filter: Expression<Bool> = onlySyncPinned
            ? (Col.group >= 0 && Col.hidden == 0)
            : (Col.hidden == 0)

        // 仅查询轻量元数据，严格排除 Col.data，避免 1.2W+ 全量同步时占用上百 MB 内存
        let sel: [Expressible] = [
            Col.id, Col.uniqueId, Col.type, Col.timestamp,
            Col.showData, Col.group, Col.tag, Col.alias
        ]

        let rows = await PasteReadStore.shared.search(
            filter: filter,
            select: sel,
            limit: nil
        )

        return rows.compactMap { row in
            guard let uniqueId = try? row.get(Col.uniqueId),
                  let timestamp = try? row.get(Col.timestamp) else {
                return nil
            }
            let rawType = (try? row.get(Col.type)) ?? ""
            let id = try? row.get(Col.id)
            let showData = try? row.get(Col.showData)
            let group = (try? row.get(Col.group)) ?? -1
            let tag = (try? row.get(Col.tag)) ?? ""
            let alias = (try? row.get(Col.alias)) ?? ""

            return SyncItemBlob(
                uniqueId: uniqueId,
                pasteboardType: rawType,
                payloadData: nil, // 延迟加载：比对时零 Payload 内存开销
                showData: showData,
                timestamp: timestamp,
                group: group,
                tag: tag,
                alias: alias,
                sourceAppName: nil,
                localRowId: id
            )
        }
    }

    // MARK: - 防抖调度 (结合低功耗模式动态调节防抖窗口)

    func markDirtyAndSchedule() {
        guard UserDefaults.standard.bool(forKey: "sync_enabled") else { return }
        isDirty = true
        dirtyGeneration &+= 1
        debounceTask?.cancel()

        let isPowerSaving = ProcessInfo.processInfo.isLowPowerModeEnabled
        let delayNanoseconds: UInt64 = isPowerSaving ? 60_000_000_000 : 15_000_000_000

        debounceTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: delayNanoseconds)
            guard !Task.isCancelled else { return }
            self?.startSyncTask()
        }
    }

    // MARK: - 仅刷新云端资产看板概要

    @discardableResult
    func fetchCloudSummary() async -> SyncSummary? {
        guard UserDefaults.standard.bool(forKey: "sync_enabled") else { return nil }
        guard !isFetchingSummary else { return syncSummary }
        isFetchingSummary = true
        addLog("正在从云端读取资产看板索引...")
        defer { isFetchingSummary = false }

        do {
            guard let serverURLString = UserDefaults.standard.string(forKey: "sync_webdav_url"),
                  let serverURL = URL(string: serverURLString),
                  let username = UserDefaults.standard.string(forKey: "sync_webdav_username"),
                  let password = SyncKeychainManager.shared.loadWebDAVPassword(),
                  let passphrase = SyncKeychainManager.shared.loadSyncPassphrase(),
                  !passphrase.isEmpty else {
                addLog("获取看板失败: 配置未完整设置", isError: true)
                return nil
            }

            let client = getCachedClient(serverURL: serverURL, username: username, password: password)
            let saltPath = "ClipboardSync/vault.meta.enc"
            let salt: Data
            do {
                salt = try await client.download(from: saltPath)
            } catch {
                addLog("获取云端密钥元数据失败: \(error.localizedDescription)", isError: true)
                return syncSummary
            }

            let masterKey = try getCachedMasterKey(passphrase: passphrase, salt: salt)

            let indexPath = "ClipboardSync/index.json.enc"
            do {
                let encIndexData = try await client.download(from: indexPath)
                guard let rawIndexData = try? SyncCryptoEngine.decrypt(data: encIndexData, using: masterKey),
                      let remoteIndex = try? JSONDecoder().decode(SyncIndex.self, from: rawIndexData) else {
                    addLog("云端索引存在但解密失败，请检查同步主密码", isError: true)
                    return syncSummary
                }

                let summary = remoteIndex.generateSummary(chips: CategoryChipStore.shared.chips)
                self.syncSummary = summary
                saveSummaryCache(summary)
                addLog("云端资产概览更新完成: 共 \(summary.totalCount) 条记录")
                return summary
            } catch {
                addLog("读取云端索引失败: \(error.localizedDescription)", isError: true)
                return syncSummary
            }
        } catch {
            addLog("获取看板异常: \(error.localizedDescription)", isError: true)
            return nil
        }
    }

    // MARK: - 从云端还原

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
        addLog("开始从云端拉取还原数据 (模式: \(overwriteLocal ? "完全覆盖" : "智能安全合并"))...")
        defer {
            isRestoring = false
            syncProgress = nil
        }

        do {
            guard let serverURLString = UserDefaults.standard.string(forKey: "sync_webdav_url"),
                  let serverURL = URL(string: serverURLString),
                  let username = UserDefaults.standard.string(forKey: "sync_webdav_username"),
                  let password = SyncKeychainManager.shared.loadWebDAVPassword(),
                  let passphrase = SyncKeychainManager.shared.loadSyncPassphrase(),
                  !passphrase.isEmpty else {
                let msg = "WebDAV 账号或同步密码未配置完整"
                restoreMessage = msg
                addLog(msg, isError: true)
                return (false, msg)
            }

            let client = getCachedClient(serverURL: serverURL, username: username, password: password)

            let saltPath = "ClipboardSync/vault.meta.enc"
            let salt: Data
            do {
                salt = try await client.download(from: saltPath)
            } catch {
                let msg = "未找到或无法读取云端密钥元数据: \(error.localizedDescription)"
                restoreMessage = msg
                addLog(msg, isError: true)
                return (false, msg)
            }
            let masterKey = try getCachedMasterKey(passphrase: passphrase, salt: salt)

            let indexPath = "ClipboardSync/index.json.enc"
            let encIndexData: Data
            do {
                encIndexData = try await client.download(from: indexPath)
            } catch {
                let msg = "下载云端索引清单失败: \(error.localizedDescription)"
                restoreMessage = msg
                addLog(msg, isError: true)
                return (false, msg)
            }

            guard let rawIndexData = try? SyncCryptoEngine.decrypt(data: encIndexData, using: masterKey),
                  let remoteIndex = try? JSONDecoder().decode(SyncIndex.self, from: rawIndexData) else {
                let msg = "解密云端索引失败，请检查同步主密码是否正确"
                restoreMessage = msg
                addLog(msg, isError: true)
                return (false, msg)
            }

            let activeEntries = remoteIndex.entries.values.filter { !$0.isDeleted }
            var toDownloadIds: [String] = []

            if overwriteLocal {
                addLog("清空本地所有记录以准备完全覆盖...")
                _ = try await PasteSQLManager.manager.clearHistory(includePinnedAndGrouped: true)
                toDownloadIds = activeEntries.map(\.uniqueId)
            } else {
                addLog("查询本地数据库全量条目以执行差集比对...")
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
                    if let localTs = localMap[entry.uniqueId] {
                        if entry.updatedAt > localTs {
                            toDownloadIds.append(entry.uniqueId)
                        }
                    } else {
                        toDownloadIds.append(entry.uniqueId)
                    }
                }
            }

            if toDownloadIds.isEmpty {
                let msg = overwriteLocal ? "云端暂无可覆盖还原的数据。" : "本地数据已是最新，无需拉取更新。"
                self.restoreMessage = msg
                addLog(msg)
                return (true, msg)
            }

            addLog("待拉取条目: \(toDownloadIds.count) 条，启动并发流水线...")
            let maxConcurrency = 3
            var restoredCount = 0
            let total = toDownloadIds.count
            var batchBuffer: [PasteboardModel] = []

            try await withThrowingTaskGroup(of: PasteboardModel?.self) { group in
                var iterator = toDownloadIds.makeIterator()

                for _ in 0..<maxConcurrency {
                    if let id = iterator.next() {
                        group.addTask {
                            let sharded = SyncIndex.shardedItemPath(for: id)
                            let legacy = SyncIndex.legacyItemPath(for: id)
                            let encData: Data? = if let d = try? await client.download(from: sharded) {
                                d
                            } else {
                                try? await client.download(from: legacy)
                            }
                            guard let encData,
                                  let rawData = try? SyncCryptoEngine.decrypt(data: encData, using: masterKey),
                                  let blob = try? JSONDecoder().decode(SyncItemBlob.self, from: rawData) else {
                                return nil
                            }
                            return await MainActor.run { blob.toPasteboardModel() }
                        }
                    }
                }

                while let model = try await group.next() {
                    if let model {
                        batchBuffer.append(model)
                        restoredCount += 1

                        if batchBuffer.count >= 50 {
                            await PasteDataStore.main.ingestSyncedBatch(batchBuffer)
                            batchBuffer.removeAll(keepingCapacity: true)
                        }

                        syncProgress = "正在还原 (\(restoredCount)/\(total))..."
                        if restoredCount % 25 == 0 || restoredCount == total {
                            addLog("还原进度: \(restoredCount)/\(total)")
                        }
                    }

                    if !Task.isCancelled, let nextId = iterator.next() {
                        group.addTask {
                            let sharded = SyncIndex.shardedItemPath(for: nextId)
                            let legacy = SyncIndex.legacyItemPath(for: nextId)
                            let encData: Data? = if let d = try? await client.download(from: sharded) {
                                d
                            } else {
                                try? await client.download(from: legacy)
                            }
                            guard let encData,
                                  let rawData = try? SyncCryptoEngine.decrypt(data: encData, using: masterKey),
                                  let blob = try? JSONDecoder().decode(SyncItemBlob.self, from: rawData) else {
                                return nil
                            }
                            return await MainActor.run { blob.toPasteboardModel() }
                        }
                    }
                }
            }

            if !batchBuffer.isEmpty {
                await PasteDataStore.main.ingestSyncedBatch(batchBuffer)
                batchBuffer.removeAll()
            }

            await PasteDataStore.main.reloadHistory()
            let summary = remoteIndex.generateSummary(chips: CategoryChipStore.shared.chips)
            self.syncSummary = summary
            saveSummaryCache(summary)

            let allPending = Array(SyncPendingDeletionsStore.shared.getAllDeletions())
            if !allPending.isEmpty {
                SyncPendingDeletionsStore.shared.clear(uniqueIds: allPending)
            }

            let msg = overwriteLocal
                ? "完全覆盖完成：已从云端拉取 \(restoredCount) 条记录并完全覆盖本地。"
                : "智能合并完成：已拉取恢复 \(restoredCount) 条云端记录，本地现有数据均已完好保留。"
            self.restoreMessage = msg
            addLog(msg)
            return (true, msg)

        } catch {
            let errorMsg = "还原失败: \(error.localizedDescription)"
            self.restoreMessage = errorMsg
            addLog(errorMsg, isError: true)
            return (false, errorMsg)
        }
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
            // 1. 检查凭据配置
            guard let serverURLString = UserDefaults.standard.string(forKey: "sync_webdav_url"),
                  let serverURL = URL(string: serverURLString),
                  let username = UserDefaults.standard.string(forKey: "sync_webdav_username"),
                  let password = SyncKeychainManager.shared.loadWebDAVPassword(),
                  let passphrase = SyncKeychainManager.shared.loadSyncPassphrase(),
                  !passphrase.isEmpty else {
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

            let client = getCachedClient(serverURL: serverURL, username: username, password: password)

            // 2. 首次或配置变动后验证目录结构
            if !hasValidatedDirectoryStructure {
                syncProgress = "验证云端目录结构..."
                let (_, latency) = try await client.testConnection()
                addLog(String(format: "服务器连通性正常，网络往返延迟: %.0f ms", latency))
                try await client.makeDirectory(path: "ClipboardSync")
                try await client.makeDirectory(path: "ClipboardSync/items")
                hasValidatedDirectoryStructure = true
            }

            if isCancelled || Task.isCancelled {
                currentState = .idle
                addLog("增量同步已取消")
                return .idle
            }

            // 3. 读取或生成加密 Salt 与复用/派生主密钥
            let saltPath = "ClipboardSync/vault.meta.enc"
            var salt: Data
            do {
                salt = try await client.download(from: saltPath)
            } catch let error as WebDAVError {
                if case .notFound = error {
                    salt = SyncCryptoEngine.generateSalt()
                    try await client.upload(data: salt, to: saltPath)
                    addLog("为全新云端空间初始化加密 Salt 元数据")
                } else {
                    let msg = "读取云端安全元数据失败: \(error.localizedDescription)"
                    addLog(msg, isError: true)
                    let state: SyncState = .failed(message: msg)
                    currentState = state
                    return state
                }
            } catch {
                let msg = "读取云端安全元数据失败: \(error.localizedDescription)"
                addLog(msg, isError: true)
                let state: SyncState = .failed(message: msg)
                currentState = state
                return state
            }

            let masterKey = try getCachedMasterKey(passphrase: passphrase, salt: salt)

            if isCancelled || Task.isCancelled {
                currentState = .idle
                addLog("增量同步已取消")
                return .idle
            }

            // 5. ETag 极速预检
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

            // 6. 下载远端索引 (严密区分 404 与网络超时/解密失败)
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

            // 7. 从 SQLite 数据库全量收集本地数据并执行 Diff
            syncProgress = "扫描本地数据库并比对差异..."
            let onlySyncPinned = self.isOnlySyncPinned
            let localBlobs = await fetchLocalBlobsForSync(onlySyncPinned: onlySyncPinned)

            if isCancelled || Task.isCancelled {
                currentState = .idle
                addLog("增量同步已取消")
                return .idle
            }

            addLog("本地 SQLite 扫描完成: 共有 \(localBlobs.count) 条待比对记录 (仅同步收藏: \(onlySyncPinned))")

            let pendingDeletions = SyncPendingDeletionsStore.shared.getAllDeletions()
            let diff = Self.calculateDiff(
                localItems: localBlobs,
                remoteIndex: remoteIndex,
                onlySyncPinned: onlySyncPinned,
                pendingDeletions: pendingDeletions
            )
            addLog("Diff 计算完成: 待上传 \(diff.toUpload.count) 条, 待下载 \(diff.toDownload.count) 条, 待清理本地 \(diff.toDeleteLocal.count) 条, 待清理远端 \(diff.toDeleteRemote.count) 条")

            // 8. 受控滑动窗口并发流水线：下载需拉取条目 (限制并发为 3)
            if !diff.toDownload.isEmpty {
                let maxConcurrency = 3
                var downloadedCount = 0
                let totalDownloads = diff.toDownload.count
                var batchBuffer: [PasteboardModel] = []

                try await withThrowingTaskGroup(of: PasteboardModel?.self) { group in
                    var iterator = diff.toDownload.makeIterator()

                    for _ in 0..<maxConcurrency {
                        if isCancelled || Task.isCancelled { break }
                        if let id = iterator.next() {
                            group.addTask {
                                let sharded = SyncIndex.shardedItemPath(for: id)
                                let legacy = SyncIndex.legacyItemPath(for: id)
                                let encData: Data? = if let d = try? await client.download(from: sharded) {
                                    d
                                } else {
                                    try? await client.download(from: legacy)
                                }
                                guard let encData,
                                      let rawData = try? SyncCryptoEngine.decrypt(data: encData, using: masterKey),
                                      let blob = try? JSONDecoder().decode(SyncItemBlob.self, from: rawData) else {
                                    return nil
                                }
                                return await MainActor.run { blob.toPasteboardModel() }
                            }
                        }
                    }

                    while let model = try await group.next() {
                        if isCancelled || Task.isCancelled { break }
                        if let model {
                            batchBuffer.append(model)
                            downloadedCount += 1

                            if batchBuffer.count >= 50 {
                                await PasteDataStore.main.ingestSyncedBatch(batchBuffer)
                                batchBuffer.removeAll(keepingCapacity: true)
                            }

                            syncProgress = "正在下载云端条目 (\(downloadedCount)/\(totalDownloads))..."
                            if downloadedCount % 25 == 0 || downloadedCount == totalDownloads {
                                addLog("下载进度: \(downloadedCount)/\(totalDownloads)")
                            }
                        }

                        if !isCancelled && !Task.isCancelled, let nextId = iterator.next() {
                            group.addTask {
                                let sharded = SyncIndex.shardedItemPath(for: nextId)
                                let legacy = SyncIndex.legacyItemPath(for: nextId)
                                let encData: Data? = if let d = try? await client.download(from: sharded) {
                                    d
                                } else {
                                    try? await client.download(from: legacy)
                                }
                                guard let encData,
                                      let rawData = try? SyncCryptoEngine.decrypt(data: encData, using: masterKey),
                                      let blob = try? JSONDecoder().decode(SyncItemBlob.self, from: rawData) else {
                                    return nil
                                }
                                return await MainActor.run { blob.toPasteboardModel() }
                            }
                        }
                    }
                }

                if !batchBuffer.isEmpty {
                    await PasteDataStore.main.ingestSyncedBatch(batchBuffer)
                    batchBuffer.removeAll()
                }
            }

            if isCancelled || Task.isCancelled {
                currentState = .idle
                addLog("增量同步已取消")
                return .idle
            }

            // 8.1 同步清理远端墓碑删除条目（保证多端一致性）
            if !diff.toDeleteLocal.isEmpty {
                addLog("检测到远端已标记删除 \(diff.toDeleteLocal.count) 条记录，正在同步清理本地 SQLite...")
                await PasteDataStore.main.deleteSyncedBatch(uniqueIds: diff.toDeleteLocal)
            }

            // 若有本地新增入库或删除清理，统一重载一次主列表
            if !diff.toDownload.isEmpty || !diff.toDeleteLocal.isEmpty {
                await PasteDataStore.main.reloadHistory()
            }

            if isCancelled || Task.isCancelled {
                currentState = .idle
                addLog("增量同步已取消")
                return .idle
            }

            // 9. 受控滑动窗口并发流水线：加密上传本地条目 (限制并发为 3，Payload 延迟按需加载，UI 节流刷新与检查点保存)
            if !diff.toUpload.isEmpty {
                let maxConcurrency = 3
                var uploadedCount = 0
                let totalUploads = diff.toUpload.count
                var ensuredDirectories = Set<String>()
                var lastUIUpdateTime = ContinuousClock.now

                try await withThrowingTaskGroup(of: (String, SyncIndexEntry)?.self) { group in
                    var iterator = diff.toUpload.makeIterator()

                    for _ in 0..<maxConcurrency {
                        if isCancelled || Task.isCancelled { break }
                        if let blob = iterator.next() {
                            let prefix = blob.uniqueId.count >= 2 ? String(blob.uniqueId.prefix(2)) : "misc"
                            let dir = "ClipboardSync/items/\(prefix)"
                            if !ensuredDirectories.contains(dir) {
                                try? await client.makeDirectory(path: dir)
                                ensuredDirectories.insert(dir)
                            }
                            group.addTask {
                                var uploadBlob = blob
                                // 关键内存优化：延迟点查 Payload，仅上传时读取，随 task 结束即刻释放
                                if uploadBlob.payloadData == nil, let rowId = uploadBlob.localRowId {
                                    uploadBlob.payloadData = PasteDataPointReader.loadData(id: rowId, uniqueId: uploadBlob.uniqueId)
                                }
                                guard let rawData = try? JSONEncoder().encode(uploadBlob),
                                      let encData = try? SyncCryptoEngine.encrypt(data: rawData, using: masterKey) else {
                                    return nil
                                }
                                let targetPath = SyncIndex.shardedItemPath(for: uploadBlob.uniqueId)
                                try await client.upload(data: encData, to: targetPath)
                                let checksum = SyncCryptoEngine.checksum(for: uploadBlob.payloadData ?? Data())
                                let estimatedSize = (uploadBlob.payloadData?.count ?? 0) + (uploadBlob.showData?.count ?? 0)
                                let entry = SyncIndexEntry(
                                    uniqueId: uploadBlob.uniqueId,
                                    updatedAt: uploadBlob.timestamp,
                                    checksum: checksum,
                                    isDeleted: false,
                                    group: uploadBlob.group,
                                    type: uploadBlob.pasteboardType,
                                    tag: uploadBlob.tag,
                                    size: estimatedSize
                                )
                                return (uploadBlob.uniqueId, entry)
                            }
                        }
                    }

                    while let result = try await group.next() {
                        if isCancelled || Task.isCancelled { break }
                        if let (id, entry) = result {
                            remoteIndex.entries[id] = entry
                            uploadedCount += 1

                            // UI 节流：每上传 25 条或每 400ms 刷新一次主线程
                            let now = ContinuousClock.now
                            if uploadedCount == totalUploads || uploadedCount % 25 == 0 || now - lastUIUpdateTime >= .milliseconds(400) {
                                lastUIUpdateTime = now
                                syncProgress = "正在加密上传 (\(uploadedCount)/\(totalUploads))..."
                                addLog("上传进度: \(uploadedCount)/\(totalUploads)")
                            }

                            // 每上传 500 条进行检查点保存，保障大批量同步中途意外中断时无需从头重传
                            if uploadedCount > 0 && uploadedCount % 500 == 0 {
                                remoteIndex.lastModified = Int64(Date().timeIntervalSince1970 * 1000)
                                if let updatedIndexData = try? JSONEncoder().encode(remoteIndex),
                                   let encUpdatedIndex = try? SyncCryptoEngine.encrypt(data: updatedIndexData, using: masterKey) {
                                    try? await client.upload(data: encUpdatedIndex, to: indexPath)
                                    addLog("已保存阶段性同步索引清单 (\(uploadedCount)/\(totalUploads))")
                                }
                            }
                        }

                        if !isCancelled && !Task.isCancelled, let nextBlob = iterator.next() {
                            let prefix = nextBlob.uniqueId.count >= 2 ? String(nextBlob.uniqueId.prefix(2)) : "misc"
                            let dir = "ClipboardSync/items/\(prefix)"
                            if !ensuredDirectories.contains(dir) {
                                try? await client.makeDirectory(path: dir)
                                ensuredDirectories.insert(dir)
                            }
                            group.addTask {
                                var uploadBlob = nextBlob
                                if uploadBlob.payloadData == nil, let rowId = uploadBlob.localRowId {
                                    uploadBlob.payloadData = PasteDataPointReader.loadData(id: rowId, uniqueId: uploadBlob.uniqueId)
                                }
                                guard let rawData = try? JSONEncoder().encode(uploadBlob),
                                      let encData = try? SyncCryptoEngine.encrypt(data: rawData, using: masterKey) else {
                                    return nil
                                }
                                let targetPath = SyncIndex.shardedItemPath(for: uploadBlob.uniqueId)
                                try await client.upload(data: encData, to: targetPath)
                                let checksum = SyncCryptoEngine.checksum(for: uploadBlob.payloadData ?? Data())
                                let estimatedSize = (uploadBlob.payloadData?.count ?? 0) + (uploadBlob.showData?.count ?? 0)
                                let entry = SyncIndexEntry(
                                    uniqueId: uploadBlob.uniqueId,
                                    updatedAt: uploadBlob.timestamp,
                                    checksum: checksum,
                                    isDeleted: false,
                                    group: uploadBlob.group,
                                    type: uploadBlob.pasteboardType,
                                    tag: uploadBlob.tag,
                                    size: estimatedSize
                                )
                                return (uploadBlob.uniqueId, entry)
                            }
                        }
                    }
                }
            }

            if isCancelled || Task.isCancelled {
                currentState = .idle
                addLog("增量同步已取消")
                return .idle
            }

            // 10. 远端删除实体文件并写入墓碑
            for id in diff.toDeleteRemote {
                if isCancelled || Task.isCancelled { break }
                try? await client.delete(path: SyncIndex.shardedItemPath(for: id))
                try? await client.delete(path: SyncIndex.legacyItemPath(for: id))
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

            if !diff.toDeleteRemote.isEmpty {
                SyncPendingDeletionsStore.shared.clear(uniqueIds: diff.toDeleteRemote)
            }

            // 10.1 自动修剪 30 天超期墓碑（保持云端索引清单极简轻量，控制内存与网络传输）
            let prunedCount = remoteIndex.pruneExpiredTombstones()
            if prunedCount > 0 {
                addLog("已自动修剪 30 天超期墓碑 \(prunedCount) 条，云端索引保持轻量")
            }

            // 11. 智能元数据回填：补全历史条目的类型与估算大小
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

            // 12. 加密上传最新索引清单并更新状态与资产看板
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

            // 统计并缓存资产看板
            let summary = remoteIndex.generateSummary(chips: CategoryChipStore.shared.chips)
            self.syncSummary = summary
            saveSummaryCache(summary)

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
