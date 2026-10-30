//
//  SyncDiffEngine.swift
//  Clipboard
//
//  增量同步 3-Way 差异计算与 LWW (Last-Write-Wins) 冲突解决纯算法引擎
//

import Foundation

enum SyncDiffEngine: Sendable {
    /// 纯函数：计算本地与远端索引的增量差异矩阵
    static func calculateDiff(
        localItems: [SyncItemBlob],
        remoteIndex: SyncIndex,
        onlySyncPinned: Bool = false,
        pendingDeletions: Set<String> = []
    ) -> SyncDiffResult {
        var diff = SyncDiffResult()
        var localMap = [String: SyncItemBlob]()

        for item in localItems {
            // 若本地处于待同步删除队列，严格排除出待上传清单
            if pendingDeletions.contains(item.uniqueId) {
                continue
            }
            // 若开启“仅同步收藏/分组”，则过滤掉普通流水 (group == -1)
            if onlySyncPinned && item.group == -1 {
                continue
            }
            localMap[item.uniqueId] = item
        }

        // 1. 遍历远端索引项
        for (id, remoteEntry) in remoteIndex.entries {
            if onlySyncPinned && remoteEntry.group == -1 {
                continue
            }

            // 优先检查本地是否主动删除了该条目：若本地已删除且远端仍存活，加入待删除远端队列
            if pendingDeletions.contains(id) {
                if !remoteEntry.isDeleted {
                    diff.toDeleteRemote.append(id)
                }
                continue
            }

            if remoteEntry.isDeleted {
                // 远端为墓碑：严格遵循 LWW (Last-Write-Wins) 准则
                if let local = localMap[id] {
                    if local.timestamp > remoteEntry.updatedAt {
                        // 本地更新时间晚于远端删除时间（删后本地又进行了复制或更新）：本地胜出，复活该项并重新上传
                        diff.toUpload.append(local)
                    } else {
                        // 远端删除时间更新或相当：同步删除本地
                        diff.toDeleteLocal.append(id)
                    }
                }
            } else if let local = localMap[id] {
                // 双端均存在：比对修改时间戳与内容哈希
                let localChecksum = local.payloadData.map { SyncCryptoEngine.checksum(for: $0) }
                if remoteEntry.updatedAt > local.timestamp {
                    if localChecksum == nil || localChecksum != remoteEntry.checksum {
                        diff.toDownload.append(id)
                    }
                } else if local.timestamp > remoteEntry.updatedAt {
                    if localChecksum == nil || localChecksum != remoteEntry.checksum {
                        diff.toUpload.append(local)
                    }
                }
            } else {
                // 远端存在且非墓碑，本地缺失：加入下载队列
                diff.toDownload.append(id)
            }
        }

        // 2. 检查本地独有项（远端尚不存在）：加入上传队列
        for item in localMap.values where remoteIndex.entries[item.uniqueId] == nil {
            diff.toUpload.append(item)
        }

        return diff
    }
}
