//
//  SyncEngine+Restore.swift
//  Clipboard
//
//  云端资产看板刷新与云端全量/合并还原流程
//

import CryptoKit
import Foundation
import SQLite

extension SyncEngine {
    // MARK: - 仅刷新云端资产看板概要

    @discardableResult
    func fetchCloudSummary() async -> SyncSummary? {
        guard UserDefaults.standard.bool(forKey: "sync_enabled") else { return nil }
        guard !isFetchingSummary else { return syncSummary }
        setFetchingSummary(true)
        addLog("正在从云端读取资产看板索引...")
        defer { setFetchingSummary(false) }

        do {
            guard let creds = resolveCredentials() else {
                addLog("获取看板失败: 配置未完整设置", isError: true)
                return nil
            }

            let client = getCachedClient(
                serverURL: creds.serverURL,
                username: creds.username,
                password: creds.password
            )
            let masterKey: SymmetricKey
            do {
                masterKey = try await loadSaltAndMasterKey(
                    client: client,
                    passphrase: creds.passphrase,
                    createIfMissing: false
                )
            } catch {
                addLog("获取云端密钥元数据失败: \(error.localizedDescription)", isError: true)
                return syncSummary
            }

            let indexPath = "ClipboardSync/index.json.enc"
            do {
                let encIndexData = try await client.download(from: indexPath)
                guard let rawIndexData = try? SyncCryptoEngine.decrypt(data: encIndexData, using: masterKey),
                      let remoteIndex = try? JSONDecoder().decode(SyncIndex.self, from: rawIndexData) else {
                    addLog("云端索引存在但解密失败，请检查同步主密码", isError: true)
                    return syncSummary
                }

                let summary = remoteIndex.generateSummary(chips: CategoryChipStore.shared.chips)
                applySummary(summary)
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

        setRestoring(true, message: nil)
        addLog("开始从云端拉取还原数据 (模式: \(overwriteLocal ? "完全覆盖" : "智能安全合并"))...")
        defer {
            setRestoring(false, message: restoreMessage)
            setProgress(nil)
        }

        do {
            guard let creds = resolveCredentials() else {
                let msg = "WebDAV 账号或同步密码未配置完整"
                setRestoreMessage(msg)
                addLog(msg, isError: true)
                return (false, msg)
            }

            let client = getCachedClient(
                serverURL: creds.serverURL,
                username: creds.username,
                password: creds.password
            )
            let masterKey: SymmetricKey
            do {
                masterKey = try await loadSaltAndMasterKey(
                    client: client,
                    passphrase: creds.passphrase,
                    createIfMissing: false
                )
            } catch {
                let msg = "未找到或无法读取云端密钥元数据: \(error.localizedDescription)"
                setRestoreMessage(msg)
                addLog(msg, isError: true)
                return (false, msg)
            }

            let indexPath = "ClipboardSync/index.json.enc"
            let encIndexData: Data
            do {
                encIndexData = try await client.download(from: indexPath)
            } catch {
                let msg = "下载云端索引清单失败: \(error.localizedDescription)"
                setRestoreMessage(msg)
                addLog(msg, isError: true)
                return (false, msg)
            }

            guard let rawIndexData = try? SyncCryptoEngine.decrypt(data: encIndexData, using: masterKey),
                  let remoteIndex = try? JSONDecoder().decode(SyncIndex.self, from: rawIndexData) else {
                let msg = "解密云端索引失败，请检查同步主密码是否正确"
                setRestoreMessage(msg)
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
                setRestoreMessage(msg)
                addLog(msg)
                return (true, msg)
            }

            addLog("待拉取条目: \(toDownloadIds.count) 条，启动并发流水线...")
            let restoredCount = try await downloadAndIngestBatches(
                ids: toDownloadIds,
                remoteEntries: remoteIndex.entries,
                client: client,
                masterKey: masterKey,
                progressVerb: "正在还原",
                logVerb: "还原进度",
                trackCorrupt: false
            )

            await PasteDataStore.main.reloadHistory()
            let summary = remoteIndex.generateSummary(chips: CategoryChipStore.shared.chips)
            applySummary(summary)

            let allPending = Array(SyncPendingDeletionsStore.shared.getAllDeletions())
            if !allPending.isEmpty {
                SyncPendingDeletionsStore.shared.clear(uniqueIds: allPending)
            }

            let msg = overwriteLocal
                ? "完全覆盖完成：已从云端拉取 \(restoredCount) 条记录并完全覆盖本地。"
                : "智能合并完成：已拉取恢复 \(restoredCount) 条云端记录，本地现有数据均已完好保留。"
            setRestoreMessage(msg)
            addLog(msg)
            return (true, msg)
        } catch {
            let errorMsg = "还原失败: \(error.localizedDescription)"
            setRestoreMessage(errorMsg)
            addLog(errorMsg, isError: true)
            return (false, errorMsg)
        }
    }
}
