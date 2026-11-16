//
//  SyncWorker.swift
//  Clipboard
//
//  独立后台同步工作 Actor：将本地元数据扫描、3-Way Diff 计算与索引加解密
//  彻底移出 @MainActor，避免全量比对与序列化阻塞主线程交互。
//

import Foundation
import SQLite

actor SyncWorker {
    static let shared = SyncWorker()

    private init() {}

    /// 在后台 Actor 中从只读库全量收集待比对元数据（零 Payload / 零缩略图常驻内存）
    func fetchLocalBlobsForSync(onlySyncPinned: Bool) async -> [SyncItemBlob] {
        let filter: Expression<Bool> = onlySyncPinned
            ? (Col.group >= 0 && Col.hidden == 0)
            : (Col.hidden == 0)

        let sel: [Expressible] = [
            Col.id, Col.uniqueId, Col.type, Col.timestamp,
            Col.group, Col.tag, Col.alias
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
            let group = (try? row.get(Col.group)) ?? -1
            let tag = (try? row.get(Col.tag)) ?? ""
            let alias = (try? row.get(Col.alias)) ?? ""

            return SyncItemBlob(
                uniqueId: uniqueId,
                pasteboardType: rawType,
                payloadData: nil,
                showData: nil,
                timestamp: timestamp,
                group: group,
                tag: tag,
                alias: alias,
                sourceAppName: nil,
                localRowId: id
            )
        }
    }

    /// 在后台 Actor 中执行 3-Way Diff 计算
    func calculateDiff(
        localItems: [SyncItemBlob],
        remoteIndex: SyncIndex,
        onlySyncPinned: Bool,
        pendingDeletions: Set<String>,
        corruptItemIDs: Set<String>
    ) -> SyncDiffResult {
        var diff = SyncDiffEngine.calculateDiff(
            localItems: localItems,
            remoteIndex: remoteIndex,
            onlySyncPinned: onlySyncPinned,
            pendingDeletions: pendingDeletions
        )
        if !corruptItemIDs.isEmpty {
            diff.toDownload.removeAll { corruptItemIDs.contains($0) }
        }
        return diff
    }
}
