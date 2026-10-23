//
//  SyncModels.swift
//  Clipboard
//
//  WebDAV 端到端加密增量同步模型协议与轻量索引结构
//

import Foundation

// MARK: - 单条索引条目（轻量元数据摘要）

struct SyncIndexEntry: Codable, Equatable, Sendable {
    /// 全局唯一 UUID（对应 PasteboardModel.uniqueId）
    let uniqueId: String
    /// 更新/创建时间戳（毫秒）
    let updatedAt: Int64
    /// 数据内容 SHA-256 前 16 位 Hex 哈希，用于快速比对内容是否有变动
    let checksum: String
    /// 墓碑标记：true 表示已被删除，用于多端协同删除（防幽灵复活）
    let isDeleted: Bool
    /// 分组 ID：-1 为普通流水，>= 0 为收藏/自定义分组
    let group: Int
}

// MARK: - 全量索引清单（存放于云端 index.json.enc）

struct SyncIndex: Codable, Sendable {
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
}

// MARK: - 单条完整数据实体（存放于云端 items/<uniqueId>.enc）

struct SyncItemBlob: Codable, Equatable, Sendable {
    let uniqueId: String
    let pasteboardType: String
    let payloadData: Data?
    let showData: Data?
    let timestamp: Int64
    let group: Int
    let tag: String
    let alias: String
    let sourceAppName: String?

    init(
        uniqueId: String,
        pasteboardType: String,
        payloadData: Data? = nil,
        showData: Data? = nil,
        timestamp: Int64,
        group: Int = -1,
        tag: String = "",
        alias: String = "",
        sourceAppName: String? = nil
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
    }
}

// MARK: - 同步差异比对结果

struct SyncDiffResult: Sendable {
    /// 云端有较新版本，需下载到本地的 uniqueId 清单
    var toDownload: [String] = []
    /// 本地有较新版本，需加密上传到云端的 Blob 清单
    var toUpload: [SyncItemBlob] = []
    /// 远端为墓碑标记，本地需执行删除的 uniqueId 清单
    var toDeleteLocal: [String] = []
    /// 本地已删除，云端需物理移除 items/<id>.enc 并打上墓碑的 uniqueId 清单
    var toDeleteRemote: [String] = []
}
