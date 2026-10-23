//
//  SyncModels.swift
//  Clipboard
//
//  WebDAV 端到端加密增量同步模型协议与轻量索引结构
//

import Foundation

// MARK: - 单条索引条目（轻量元数据摘要）

nonisolated struct SyncIndexEntry: Codable, Equatable, Sendable {
    /// 全局唯一 UUID（对应 PasteboardModel.uniqueId）
    let uniqueId: String
    /// 更新/创建时间戳（毫秒）
    let updatedAt: Int64
    /// 数据内容 SHA-256 前 16 位 Hex 哈希，用于快速比对内容是否有变动
    let checksum: String
    /// 墓碑标记：true 表示已被删除，用于多端协同删除（防幽灵复活）
    let isDeleted: Bool
    /// 分组 ID：-1 为普通流水，>= 0 为收藏/自定义分组
    var group: Int
    /// 媒体类型（如 text, image 等）
    var type: String? = nil
    /// 标签名称（如有）
    var tag: String? = nil
    /// 数据估算大小（字节数）
    var size: Int? = nil

    init(
        uniqueId: String,
        updatedAt: Int64,
        checksum: String,
        isDeleted: Bool,
        group: Int,
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
}

// MARK: - 云端资产统计细分模型

nonisolated struct SyncGroupCount: Codable, Identifiable, Equatable, Sendable {
    var id: String { "\(groupId)_\(name)" }
    let groupId: Int
    let name: String
    let count: Int
    let colorHex: String?
}

nonisolated struct SyncTypeCount: Codable, Identifiable, Equatable, Sendable {
    var id: String { typeName }
    let typeName: String
    let count: Int
}

nonisolated struct SyncSummary: Codable, Equatable, Sendable {
    let totalCount: Int
    let totalBytes: Int64
    let groupCounts: [SyncGroupCount]
    let typeCounts: [SyncTypeCount]
    let lastUpdated: Int64

    var formattedStorageSize: String {
        ByteCountFormatter.string(fromByteCount: totalBytes, countStyle: .file)
    }
}

// MARK: - 全量索引清单（存放于云端 index.json.enc）

nonisolated struct SyncIndex: Codable, Sendable {
    /// 索引 Schema 版本号
    let version: Int
    /// 索引最近修改时间戳（毫秒）
    var lastModified: Int64
    /// 所有条目的字典表，Key 为 uniqueId
    var entries: [String: SyncIndexEntry]

    init(version: Int = 1, lastModified: Int64 = Int64(Date().timeIntervalSince1970 * 1000), entries: [String: SyncIndexEntry] = [:]) {
        self.version = version
        self.lastModified = lastModified
        self.entries = entries
    }

    /// 毫秒级生成云端资产概览摘要（过滤墓碑，按分组和类型细分）
    func generateSummary(chips: [CategoryChip]) -> SyncSummary {
        let activeEntries = entries.values.filter { !$0.isDeleted }
        let totalCount = activeEntries.count
        var totalBytes: Int64 = 0

        // 1. 按分组统计
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

        var typeCounts = typeMap.map { SyncTypeCount(typeName: $0.key, count: $0.value) }
        typeCounts.sort { $0.count > $1.count }

        return SyncSummary(
            totalCount: totalCount,
            totalBytes: totalBytes,
            groupCounts: groupCounts,
            typeCounts: typeCounts,
            lastUpdated: lastModified
        )
    }
}

// MARK: - 云端路径映射与 Git 风格分片规范

extension SyncIndex {
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

nonisolated struct SyncDiffResult: Sendable {
    /// 云端有较新版本，需下载到本地的 uniqueId 清单
    var toDownload: [String] = []
    /// 本地有较新版本，需加密上传到云端的 Blob 清单
    var toUpload: [SyncItemBlob] = []
    /// 远端为墓碑标记，本地需执行删除的 uniqueId 清单
    var toDeleteLocal: [String] = []
    /// 本地已删除，云端需物理移除 items/<id>.enc 并打上墓碑的 uniqueId 清单
    var toDeleteRemote: [String] = []
}
