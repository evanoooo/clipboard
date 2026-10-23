//
//  SyncModels.swift
//  Clipboard
//
//  WebDAV 端到端加密同步协议数据模型：清单索引、分片路径规范、加密载荷与差异结果
//

import Foundation

// MARK: - 远端云端索引清单中的单条元数据条目

nonisolated struct SyncIndexEntry: Codable, Equatable, Sendable {
    let uniqueId: String
    let updatedAt: Int64
    let checksum: String
    var isDeleted: Bool
    var group: Int
    var type: String?
    var tag: String?
    var size: Int?

    enum CodingKeys: String, CodingKey {
        case uniqueId, updatedAt, checksum, isDeleted, group, type, tag, size
    }

    init(
        uniqueId: String,
        updatedAt: Int64,
        checksum: String,
        isDeleted: Bool = false,
        group: Int = -1,
        type: String? = nil,
        tag: String? = nil,
        size: Int? = nil
    ) {
        self.uniqueId = uniqueId
        self.updatedAt = updatedAt
        self.checksum = checksum
        self.isDeleted = isDeleted
        self.group = group
        self.type = type
        self.tag = tag
        self.size = size
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.uniqueId = try container.decode(String.self, forKey: .uniqueId)
        self.updatedAt = try container.decode(Int64.self, forKey: .updatedAt)
        self.checksum = try container.decode(String.self, forKey: .checksum)
        self.isDeleted = try container.decodeIfPresent(Bool.self, forKey: .isDeleted) ?? false
        self.group = try container.decodeIfPresent(Int.self, forKey: .group) ?? -1
        self.type = try container.decodeIfPresent(String.self, forKey: .type)
        self.tag = try container.decodeIfPresent(String.self, forKey: .tag)
        self.size = try container.decodeIfPresent(Int.self, forKey: .size)
    }
}

// MARK: - 资产看板统计结构体

nonisolated struct SyncSummary: Codable, Equatable, Sendable {
    let totalCount: Int
    let totalBytes: Int64
    let groupCounts: [SyncGroupCount]
    let typeCounts: [SyncTypeCount]
    let lastUpdated: Int64

    var totalSizeBytes: Int64 { totalBytes }
    var lastSyncTime: Int64 { lastUpdated }

    var formattedStorageSize: String {
        ByteCountFormatter.string(fromByteCount: totalBytes, countStyle: .file)
    }

    var formattedTotalSize: String { formattedStorageSize }

    var formattedLastUpdated: String {
        let date = Date(timeIntervalSince1970: Double(lastUpdated) / 1000.0)
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter.string(from: date)
    }

    var formattedLastSyncTime: String { formattedLastUpdated }
}

nonisolated struct SyncGroupCount: Codable, Equatable, Identifiable, Sendable {
    var id: Int { groupId }
    let groupId: Int
    let name: String
    let count: Int
    let colorHex: String?
}

nonisolated struct SyncTypeCount: Codable, Equatable, Identifiable, Sendable {
    var id: String { typeName }
    let typeName: String
    let count: Int
}

// MARK: - 远端全局索引文件结构（对应 index.json.enc）

nonisolated struct SyncIndex: Codable, Sendable {
    var version: Int
    var lastModified: Int64
    var entries: [String: SyncIndexEntry]

    init(
        version: Int = 1,
        lastModified: Int64 = Int64(Date().timeIntervalSince1970 * 1000),
        entries: [String: SyncIndexEntry] = [:]
    ) {
        self.version = version
        self.lastModified = lastModified
        self.entries = entries
    }

    /// 根据当前索引元数据即时计算统计看板摘要（无需下载实体数据）
    @MainActor
    func generateSummary(chips: [CategoryChip] = []) -> SyncSummary {
        let activeEntries = entries.values.filter { !$0.isDeleted }
        let totalCount = activeEntries.count
        var totalBytes: Int64 = 0

        // 1. 按分组统计（匹配本地 Chip 名称与颜色）
        var groupMap: [Int: Int] = [:]
        for entry in activeEntries {
            groupMap[entry.group, default: 0] += 1
            totalBytes += Int64(entry.size ?? 128)
        }

        let chipDict = Dictionary(chips.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var groupCounts: [SyncGroupCount] = []
        for (groupId, count) in groupMap {
            if groupId == -1 {
                groupCounts.append(SyncGroupCount(
                    groupId: -1,
                    name: String(localized: "clipboard"),
                    count: count,
                    colorHex: nil
                ))
            } else if let chip = chipDict[groupId] {
                groupCounts.append(SyncGroupCount(
                    groupId: groupId,
                    name: chip.name,
                    count: count,
                    colorHex: chip.customHexColor
                ))
            } else {
                groupCounts.append(SyncGroupCount(
                    groupId: groupId,
                    name: "分类 #\(groupId)",
                    count: count,
                    colorHex: nil
                ))
            }
        }

        // 默认剪贴板优先，其余按数量降序
        groupCounts.sort { a, b in
            if a.groupId == -1 { return true }
            if b.groupId == -1 { return false }
            return a.count > b.count
        }

        // 2. 按媒体类型统计（智能归类，不再出现模糊的“记录”）
        var typeMap: [String: Int] = [:]
        for entry in activeEntries {
            let t = entry.type?.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
            let typeName: String
            if let t, !t.isEmpty {
                if t.contains("image") || t.contains("png") || t.contains("tiff") || t.contains("jpeg") {
                    typeName = "图片"
                } else if t.contains("url") || t.contains("link") {
                    typeName = "链接"
                } else if t.contains("rtf") || t.contains("html") {
                    typeName = "富文本"
                } else if t.contains("file") || t.contains("path") {
                    typeName = "文件"
                } else if t.contains("color") {
                    typeName = "颜色"
                } else {
                    typeName = "文本"
                }
            } else {
                typeName = "文本"
            }
            typeMap[typeName, default: 0] += 1
        }

        let typeCounts = typeMap.map { SyncTypeCount(typeName: $0.key, count: $0.value) }
            .sorted { $0.count > $1.count }

        return SyncSummary(
            totalCount: totalCount,
            totalBytes: totalBytes,
            groupCounts: groupCounts,
            typeCounts: typeCounts,
            lastUpdated: lastModified
        )
    }
}

// MARK: - 云端路径映射与 Git 风格分片规范及墓碑修剪

extension SyncIndex {
    /// 修剪超过指定保留天数的已删除墓碑记录，防止索引文件随时间无限膨胀
    @discardableResult
    public mutating func pruneExpiredTombstones(
        retentionDays: Int = 30,
        currentTimeMillis: Int64 = Int64(Date().timeIntervalSince1970 * 1000)
    ) -> Int {
        let cutoff = currentTimeMillis - Int64(retentionDays * 24 * 3600 * 1000)
        let expiredKeys = entries.compactMap { (key, entry) -> String? in
            (entry.isDeleted && entry.updatedAt < cutoff) ? key : nil
        }
        for key in expiredKeys {
            entries.removeValue(forKey: key)
        }
        return expiredKeys.count
    }

    /// Git 风格 2 字符前缀分片子目录路径 (如 ClipboardSync/items/00/0007e2a8....enc)
    public nonisolated static func shardedItemPath(for uniqueId: String) -> String {
        let prefix = uniqueId.count >= 2 ? String(uniqueId.prefix(2)) : "misc"
        return "ClipboardSync/items/\(prefix)/\(uniqueId).enc"
    }

    /// 历史平铺单目录路径 (向下兼容已上传的条目)
    public nonisolated static func legacyItemPath(for uniqueId: String) -> String {
        "ClipboardSync/items/\(uniqueId).enc"
    }
}

// MARK: - 单条完整数据实体（存放于云端 items/<uniqueId>.enc）

nonisolated struct SyncItemBlob: Codable, Equatable, Sendable {
    let uniqueId: String
    let pasteboardType: String
    var payloadData: Data?
    var showData: Data?
    let timestamp: Int64
    let group: Int
    let tag: String
    let alias: String
    let sourceAppName: String?
    var localRowId: Int64?

    enum CodingKeys: String, CodingKey {
        case uniqueId, pasteboardType, payloadData, showData, timestamp, group, tag, alias, sourceAppName
    }

    init(
        uniqueId: String,
        pasteboardType: String,
        payloadData: Data? = nil,
        showData: Data? = nil,
        timestamp: Int64,
        group: Int = -1,
        tag: String = "",
        alias: String = "",
        sourceAppName: String? = nil,
        localRowId: Int64? = nil
    ) {
        self.uniqueId = uniqueId
        self.pasteboardType = pasteboardType
        self.payloadData = payloadData
        self.showData = showData
        self.timestamp = timestamp
        self.group = group
        self.tag = tag
        self.alias = alias
        self.sourceAppName = sourceAppName
        self.localRowId = localRowId
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.uniqueId = try container.decode(String.self, forKey: .uniqueId)
        self.pasteboardType = try container.decode(String.self, forKey: .pasteboardType)
        self.payloadData = try container.decodeIfPresent(Data.self, forKey: .payloadData)
        self.showData = try container.decodeIfPresent(Data.self, forKey: .showData)
        self.timestamp = try container.decode(Int64.self, forKey: .timestamp)
        self.group = try container.decodeIfPresent(Int.self, forKey: .group) ?? -1
        self.tag = try container.decodeIfPresent(String.self, forKey: .tag) ?? ""
        self.alias = try container.decodeIfPresent(String.self, forKey: .alias) ?? ""
        self.sourceAppName = try container.decodeIfPresent(String.self, forKey: .sourceAppName)
        self.localRowId = nil
    }
}

// MARK: - 同步差异比对结果

typealias SyncDiff = SyncDiffResult

nonisolated struct SyncDiffResult: Sendable {
    /// 云端有较新版本，需下载到本地的 uniqueId 清单
    var toDownload: [String] = []
    /// 本地有较新版本，需加密上传到云端的 Blob 清单
    var toUpload: [SyncItemBlob] = []
    /// 远端为墓碑标记，本地需执行删除的 uniqueId 清单
    var toDeleteLocal: [String] = []
    /// 本地已从收藏中移除，远端需标记为删除的 uniqueId 清单
    var toDeleteRemote: [String] = []
}


// MARK: - 本地待同步删除存储（保障双端删除一致性，杜绝删除复活）

final class SyncPendingDeletionsStore: @unchecked Sendable {
    static let shared = SyncPendingDeletionsStore()

    private let queue = DispatchQueue(label: "com.crown.clipboard.sync.deletions", attributes: .concurrent)
    private var deletedIds: Set<String> = []
    private let storageKey = "sync_pending_deleted_unique_ids"

    private init() {
        if let array = UserDefaults.standard.stringArray(forKey: storageKey) {
            deletedIds = Set(array)
        }
    }

    func recordDeletions(uniqueIds: [String]) {
        guard !uniqueIds.isEmpty else { return }
        queue.async(flags: .barrier) {
            self.deletedIds.formUnion(uniqueIds)
            self.persist()
        }
    }

    func removeDeletions(uniqueIds: [String]) {
        guard !uniqueIds.isEmpty else { return }
        queue.async(flags: .barrier) {
            self.deletedIds.subtract(uniqueIds)
            self.persist()
        }
    }

    func getAllDeletions() -> Set<String> {
        queue.sync {
            deletedIds
        }
    }

    func clear(uniqueIds: [String]) {
        guard !uniqueIds.isEmpty else { return }
        queue.async(flags: .barrier) {
            self.deletedIds.subtract(uniqueIds)
            self.persist()
        }
    }

    private func persist() {
        UserDefaults.standard.set(Array(deletedIds), forKey: storageKey)
    }
}
