// ClipboardSchema.swift

import Foundation
import SQLite

// MARK: - Column definitions

struct Col {
    nonisolated static let id = Expression<Int64>("id")
    nonisolated static let uniqueId = Expression<String>("unique_id")
    nonisolated static let type = Expression<String>("type")
    nonisolated static let data = Expression<Data>("data")
    /// 小数据内联表达式：长度 <= 4KB 时直接在列表查询中返回，零磁盘点查；超过 4KB 返回 NULL
    nonisolated static let inlineData = Expression<Data?>(
        literal: "CASE WHEN LENGTH(data) <= 4096 THEN data END"
    )
    nonisolated static let showData = Expression<Data?>("show_data")
    nonisolated static let timestamp = Expression<Int64>("timestamp")
    nonisolated static let sortOrder = Expression<Int64>("sort_order")
    nonisolated static let orderStep: Int64 = 65_536
    nonisolated static let nextSortOrder = Expression<Int64>(
        literal: "(SELECT COALESCE(MAX(sort_order), 0) + 65536 FROM Clip)"
    )
    nonisolated static let appID = Expression<Int64>("app_id")
    // 仅供旧备份导入使用。
    nonisolated static let appPath = Expression<String>("app_path")
    nonisolated static let appName = Expression<String>("app_name")
    nonisolated static let searchText = Expression<String>("search_text")
    nonisolated static let length = Expression<Int>("length")
    nonisolated static let group = Expression<Int>("group")
    nonisolated static let tag = Expression<String?>("tag")
    /// 用户别名原文，仅用于展示与检索，不参与类型判定。
    nonisolated static let alias = Expression<String?>("alias")
    /// 别名归一化文本，检索专用（与 `search_text` 同一套归一化）。
    nonisolated static let aliasSearch = Expression<String?>("alias_search")
    nonisolated static let hidden = Expression<Int>("hidden")
    /// 外部 CAS 媒体相对路径（位于 `.media/blobs/` 下）；历史未迁移条目为 nil
    nonisolated static let mediaRelPath = Expression<String?>("media_rel_path")
    /// 外部 CAS 媒体字节大小；历史未迁移条目为 0
    nonisolated static let mediaSize = Expression<Int64>("media_size")

    private init() {}
}

// MARK: - Shared paths

enum ClipboardPaths {
    static let appBundleId = "com.crown.clipboard"

    private static var appSupportDir: URL {
        URL.applicationSupportDirectory.appending(path: appBundleId)
    }

    /// ~/Library/Application Support/com.crown.clipboard/Clip.sqlite3
    static var database: String {
        appSupportDir.appending(path: "Clip.sqlite3").path
    }

    /// ~/Library/Application Support/com.crown.clipboard/ClipArchive.sqlite3
    static var archiveDatabase: String {
        appSupportDir.appending(path: "ClipArchive.sqlite3").path
    }
}
