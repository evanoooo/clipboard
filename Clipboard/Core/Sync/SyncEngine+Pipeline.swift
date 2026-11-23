//
//  SyncEngine+Pipeline.swift
//  Clipboard
//
//  云同步凭据解析、密钥元数据加载以及受控滑动窗口并发上传/下载流水线
//

import CryptoKit
import Foundation

struct SyncCredentials {
    let serverURL: URL
    let username: String?
    let password: String?
    let passphrase: String
}

enum SyncPipelineError: LocalizedError {
    case custom(String)

    var errorDescription: String? {
        switch self {
        case let .custom(message):
            return message
        }
    }
}

extension SyncEngine {
    func resolveCredentials() -> SyncCredentials? {
        guard let serverURLString = UserDefaults.standard.string(forKey: "sync_webdav_url"),
              let serverURL = URL(string: serverURLString),
              let username = UserDefaults.standard.string(forKey: "sync_webdav_username"),
              let password = SyncKeychainManager.shared.loadWebDAVPassword(),
              let passphrase = SyncKeychainManager.shared.loadSyncPassphrase(),
              !passphrase.isEmpty else {
            return nil
        }
        return SyncCredentials(
            serverURL: serverURL,
            username: username,
            password: password,
            passphrase: passphrase
        )
    }

    func loadSaltAndMasterKey(
        client: WebDAVClient,
        passphrase: String,
        createIfMissing: Bool
    ) async throws -> SymmetricKey {
        let saltPath = "ClipboardSync/vault.meta.enc"
        let salt: Data
        do {
            salt = try await client.download(from: saltPath)
        } catch let error as WebDAVError {
            if case .notFound = error, createIfMissing {
                let generated = SyncCryptoEngine.generateSalt()
                try await client.upload(data: generated, to: saltPath)
                addLog("为全新云端空间初始化加密 Salt 元数据")
                salt = generated
            } else {
                throw error
            }
        }
        return try getCachedMasterKey(passphrase: passphrase, salt: salt)
    }

    /// 并发滑动窗口下载并分批入库（限流并发 3、在途字节上限 24MB）
    func downloadAndIngestBatches(
        ids: [String],
        remoteEntries: [String: SyncIndexEntry],
        client: WebDAVClient,
        masterKey: SymmetricKey,
        progressVerb: String,
        logVerb: String,
        trackCorrupt: Bool
    ) async throws -> Int {
        guard !ids.isEmpty else { return 0 }

        let maxConcurrency = 3
        let budgetLimiter = SyncByteBudgetLimiter(maxBudgetBytes: 24 * 1024 * 1024)
        var completedCount = 0
        let totalCount = ids.count
        var batchBuffer: [SyncItemBlob] = []
        var batchBufferBytes = 0

        try await withThrowingTaskGroup(of: SyncItemBlob?.self) { group in
            var iterator = ids.makeIterator()

            @MainActor
            func enqueueNextIfAvailable() {
                guard !isCancelled, !Task.isCancelled, let itemId = iterator.next() else { return }
                let estBytes = Self.estimatedDownloadBytes(id: itemId, entry: remoteEntries[itemId])
                group.addTask { [weak self] in
                    let acquired = await budgetLimiter.acquire(estimatedBytes: estBytes)
                    defer { Task { await budgetLimiter.release(acquiredBytes: acquired) } }

                    let encData = await Self.downloadItemData(id: itemId, client: client)
                    guard let encData else { return nil }
                    guard let rawData = try? SyncCryptoEngine.decrypt(data: encData, using: masterKey),
                          let blob = try? JSONDecoder().decode(SyncItemBlob.self, from: rawData) else {
                        if trackCorrupt {
                            Log.sync.warn("云端条目 [\(itemId)] 解密或解码失败，已记录黑名单跳过循环重试")
                            await MainActor.run {
                                self?.recordCorruptItem(id: itemId)
                            }
                        } else {
                            Log.sync.warn("云端条目 [\(itemId)] 解密或解码失败，可能已损坏")
                        }
                        return nil
                    }
                    return blob
                }
            }

            for _ in 0..<maxConcurrency {
                enqueueNextIfAvailable()
            }

            while let blob = try await group.next() {
                if isCancelled || Task.isCancelled {
                    group.cancelAll()
                    break
                }
                if let blob {
                    batchBuffer.append(blob)
                    batchBufferBytes += blob.payloadData?.count ?? 0
                    completedCount += 1

                    if batchBuffer.count >= 50 || batchBufferBytes >= 16 * 1024 * 1024 {
                        await PasteDataStore.main.ingestSyncedBlobs(batchBuffer)
                        batchBuffer.removeAll(keepingCapacity: true)
                        batchBufferBytes = 0
                    }

                    setProgress("\(progressVerb) (\(completedCount)/\(totalCount))...")
                    if completedCount % 25 == 0 || completedCount == totalCount {
                        addLog("\(logVerb): \(completedCount)/\(totalCount)")
                    }
                }
                enqueueNextIfAvailable()
            }
        }

        if !batchBuffer.isEmpty {
            await PasteDataStore.main.ingestSyncedBlobs(batchBuffer)
            batchBuffer.removeAll()
        }

        return completedCount
    }

    /// 并发滑动窗口加密上传（限流并发 3、在途字节上限 24MB、延迟按需读取与每 500 条检查点落盘）
    func uploadBatches(
        blobs: [SyncItemBlob],
        remoteIndex: inout SyncIndex,
        client: WebDAVClient,
        masterKey: SymmetricKey,
        indexPath: String
    ) async throws {
        guard !blobs.isEmpty else { return }

        let maxConcurrency = 3
        let uploadBudgetLimiter = SyncByteBudgetLimiter(maxBudgetBytes: 24 * 1024 * 1024)
        var uploadedCount = 0
        let totalUploads = blobs.count
        var ensuredDirectories = Set<String>()
        var lastUIUpdateTime = ContinuousClock.now

        try await withThrowingTaskGroup(of: (String, SyncIndexEntry)?.self) { group in
            var iterator = blobs.makeIterator()

            @MainActor
            func enqueueNextIfAvailable() async {
                guard !isCancelled, !Task.isCancelled, let blob = iterator.next() else { return }
                let prefix = blob.uniqueId.count >= 2 ? String(blob.uniqueId.prefix(2)) : "misc"
                let dir = "ClipboardSync/items/\(prefix)"
                if !ensuredDirectories.contains(dir) {
                    try? await client.makeDirectory(path: dir)
                    ensuredDirectories.insert(dir)
                }

                let estBytes = Self.estimatedUploadBytes(for: blob)
                group.addTask {
                    let acquired = await uploadBudgetLimiter.acquire(estimatedBytes: estBytes)
                    defer { Task { await uploadBudgetLimiter.release(acquiredBytes: acquired) } }

                    var uploadBlob = blob
                    if uploadBlob.payloadData == nil, let rowId = uploadBlob.localRowId {
                        uploadBlob.payloadData = PasteDataPointReader.loadData(
                            id: rowId,
                            uniqueId: uploadBlob.uniqueId,
                            channel: .bulk
                        )
                    }
                    if uploadBlob.showData == nil, let rowId = uploadBlob.localRowId {
                        uploadBlob.showData = PasteDataPointReader.loadShowData(
                            id: rowId,
                            uniqueId: uploadBlob.uniqueId
                        )
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

            for _ in 0..<maxConcurrency {
                await enqueueNextIfAvailable()
            }

            while let result = try await group.next() {
                if isCancelled || Task.isCancelled {
                    group.cancelAll()
                    break
                }
                if let (id, entry) = result {
                    remoteIndex.entries[id] = entry
                    uploadedCount += 1

                    let now = ContinuousClock.now
                    if uploadedCount == totalUploads
                        || uploadedCount % 25 == 0
                        || now - lastUIUpdateTime >= .milliseconds(400) {
                        lastUIUpdateTime = now
                        setProgress("正在加密上传 (\(uploadedCount)/\(totalUploads))...")
                        addLog("上传进度: \(uploadedCount)/\(totalUploads)")
                    }

                    if uploadedCount > 0 && uploadedCount % 500 == 0 {
                        remoteIndex.lastModified = Int64(Date().timeIntervalSince1970 * 1000)
                        if let updatedIndexData = try? JSONEncoder().encode(remoteIndex),
                           let encUpdatedIndex = try? SyncCryptoEngine.encrypt(data: updatedIndexData, using: masterKey) {
                            try? await client.upload(data: encUpdatedIndex, to: indexPath)
                            addLog("已保存阶段性同步索引清单 (\(uploadedCount)/\(totalUploads))")
                        }
                    }
                }
                await enqueueNextIfAvailable()
            }
        }
    }
}
