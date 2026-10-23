//
//  SyncEngine.swift
//  Clipboard
//
//  WebDAV 增量同步调度引擎：Diff 比对、LWW 冲突裁决、15s 防抖与并发传输管线
//

import Combine
import CryptoKit
import Foundation

enum SyncState: Sendable, Equatable {
    case idle
    case syncing
    case success(lastSyncTime: Int64)
    case failed(message: String)

    var displayText: String {
        switch self {
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
    private var lastRemoteETag: String?
    private var isDirty = false
    private var debounceTask: Task<Void, Never>?

    private init() {}

    // MARK: - 静态纯函数：Diff 计算矩阵 (供测试与引擎共享)

    static func calculateDiff(
        localItems: [SyncItemBlob],
        remoteIndex: SyncIndex,
        onlySyncPinned: Bool = false
    ) -> SyncDiffResult {
        SyncDiffEngine.calculateDiff(localItems: localItems, remoteIndex: remoteIndex, onlySyncPinned: onlySyncPinned)
    }

    // MARK: - 防抖调度 (Debounce 15s)

    func markDirtyAndSchedule() {
        isDirty = true
        debounceTask?.cancel()
        debounceTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 15_000_000_000) // 15秒防抖
            guard !Task.isCancelled else { return }
            await self?.triggerSync()
        }
    }

    // MARK: - 手动或定时触发同步

    @discardableResult
    func triggerSync() async -> SyncState {
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

            // 6. 收集本地数据与执行 Diff
            let onlySyncPinned = UserDefaults.standard.bool(forKey: "sync_only_pinned")
            let localModels = PasteDataStore.main.dataList.value
            let localBlobs = localModels.map { SyncItemBlob(from: $0) }

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
                        let entry = SyncIndexEntry(
                            uniqueId: blob.uniqueId,
                            updatedAt: blob.timestamp,
                            checksum: checksum,
                            isDeleted: false,
                            group: blob.group
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
                    group: -1
                )
            }

            // 10. 加密上传最新索引清单并更新状态
            remoteIndex.lastModified = Int64(Date().timeIntervalSince1970 * 1000)
            let updatedIndexData = try JSONEncoder().encode(remoteIndex)
            let encUpdatedIndex = try SyncCryptoEngine.encrypt(data: updatedIndexData, using: masterKey)
            try await client.upload(data: encUpdatedIndex, to: indexPath)

            self.lastRemoteETag = try? await client.getETag(path: indexPath)
            self.isDirty = false

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
