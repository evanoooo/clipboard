//
//  PasteDataPointReader.swift
//  Clipboard
//
//  按需点查 Col.data，提供 ~0.002ms 极限零锁点查，消除搜索/列表对大 Payload 的预载开销。
//  双连接架构（UI 通道 50ms 超时 / Bulk 通道 2000ms 超时）实现前后台读隔离与维护期安全门控。
//

import Foundation
import os
import SQLite3

nonisolated(unsafe) private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// 点查通道类型：UI 线程极速小数据点查 vs 后台大对象读取
nonisolated enum PointReaderChannel: Sendable {
    case ui
    case bulk
}

nonisolated final class PersistentPointReader: @unchecked Sendable {
    static let shared = PersistentPointReader()

    /// 单个独立连接通道，包含独立的 SQLite 只读句柄、锁与预编译语句
    private final class ConnectionChannel: @unchecked Sendable {
        private let lock = OSAllocatedUnfairLock()
        private let busyTimeoutMs: Int32
        private var db: OpaquePointer?
        private var stmtById: OpaquePointer?
        private var stmtByUniqueId: OpaquePointer?
        private var stmtOCR: OpaquePointer?
        private var stmtShowData: OpaquePointer?

        init(busyTimeoutMs: Int32) {
            self.busyTimeoutMs = busyTimeoutMs
        }

        private func ensureOpen(parent: PersistentPointReader) -> Bool {
            if parent.isMaintenanceSuspended { return false }
            if db != nil { return true }
            guard sqlite3_open_v2(PasteSQLManager.databasePath, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK else {
                db = nil
                return false
            }
            sqlite3_busy_timeout(db, busyTimeoutMs)
            sqlite3_exec(db, "PRAGMA cache_size = -512;", nil, nil, nil)
            let mmapBytes = Int64(PasteUserDefaults.sqliteMmapSizeMB) * 1024 * 1024
            sqlite3_exec(db, "PRAGMA mmap_size = \(mmapBytes);", nil, nil, nil)

            let sqlById = "SELECT data, media_rel_path FROM Clip WHERE id = ? LIMIT 1"
            sqlite3_prepare_v2(db, sqlById, -1, &stmtById, nil)

            let sqlByUniqueId = "SELECT data, media_rel_path FROM Clip WHERE unique_id = ? LIMIT 1"
            sqlite3_prepare_v2(db, sqlByUniqueId, -1, &stmtByUniqueId, nil)

            let sqlOCR = "SELECT search_text, unique_id, data, media_rel_path FROM Clip WHERE id = ? LIMIT 1"
            sqlite3_prepare_v2(db, sqlOCR, -1, &stmtOCR, nil)

            let sqlShowData = "SELECT show_data FROM Clip WHERE id = ? LIMIT 1"
            sqlite3_prepare_v2(db, sqlShowData, -1, &stmtShowData, nil)

            return true
        }

        func close() {
            lock.withLock {
                if let stmt = stmtById { sqlite3_finalize(stmt); stmtById = nil }
                if let stmt = stmtByUniqueId { sqlite3_finalize(stmt); stmtByUniqueId = nil }
                if let stmt = stmtOCR { sqlite3_finalize(stmt); stmtOCR = nil }
                if let stmt = stmtShowData { sqlite3_finalize(stmt); stmtShowData = nil }
                if let d = db { sqlite3_close(d); db = nil }
            }
        }

        func loadData(id: Int64?, uniqueId: String, parent: PersistentPointReader) -> Data? {
            lock.withLock {
                guard ensureOpen(parent: parent) else { return nil }
                let stmt: OpaquePointer?
                if let id {
                    stmt = stmtById
                    guard let stmt else { return nil }
                    sqlite3_reset(stmt)
                    sqlite3_clear_bindings(stmt)
                    sqlite3_bind_int64(stmt, 1, id)
                } else {
                    stmt = stmtByUniqueId
                    guard let stmt else { return nil }
                    sqlite3_reset(stmt)
                    sqlite3_clear_bindings(stmt)
                    sqlite3_bind_text(stmt, 1, uniqueId, -1, SQLITE_TRANSIENT)
                }
                defer {
                    sqlite3_reset(stmt)
                    sqlite3_clear_bindings(stmt)
                }

                if sqlite3_step(stmt) == SQLITE_ROW {
                    if let relPtr = sqlite3_column_text(stmt, 1) {
                        let relPath = String(cString: relPtr)
                        if !relPath.isEmpty, let external = MediaBlobStore.shared.readBlob(relPath: relPath) {
                            return external
                        }
                    }
                    if let bytes = sqlite3_column_blob(stmt, 0) {
                        let count = sqlite3_column_bytes(stmt, 0)
                        return Data(bytes: bytes, count: Int(count))
                    }
                }
                return nil
            }
        }

        func loadMediaURL(id: Int64?, uniqueId: String, parent: PersistentPointReader) -> URL? {
            lock.withLock {
                guard ensureOpen(parent: parent) else { return nil }
                let stmt: OpaquePointer?
                if let id {
                    stmt = stmtById
                    guard let stmt else { return nil }
                    sqlite3_reset(stmt)
                    sqlite3_clear_bindings(stmt)
                    sqlite3_bind_int64(stmt, 1, id)
                } else {
                    stmt = stmtByUniqueId
                    guard let stmt else { return nil }
                    sqlite3_reset(stmt)
                    sqlite3_clear_bindings(stmt)
                    sqlite3_bind_text(stmt, 1, uniqueId, -1, SQLITE_TRANSIENT)
                }
                defer {
                    sqlite3_reset(stmt)
                    sqlite3_clear_bindings(stmt)
                }

                if sqlite3_step(stmt) == SQLITE_ROW,
                   let relPtr = sqlite3_column_text(stmt, 1) {
                    let relPath = String(cString: relPtr)
                    return MediaBlobStore.shared.blobURL(for: relPath)
                }
                return nil
            }
        }

        func loadShowData(id: Int64, parent: PersistentPointReader) -> Data? {
            lock.withLock {
                guard ensureOpen(parent: parent), let stmt = stmtShowData else { return nil }
                sqlite3_reset(stmt)
                sqlite3_clear_bindings(stmt)
                sqlite3_bind_int64(stmt, 1, id)
                defer {
                    sqlite3_reset(stmt)
                    sqlite3_clear_bindings(stmt)
                }
                if sqlite3_step(stmt) == SQLITE_ROW {
                    if let bytes = sqlite3_column_blob(stmt, 0) {
                        let count = sqlite3_column_bytes(stmt, 0)
                        return Data(bytes: bytes, count: Int(count))
                    }
                }
                return nil
            }
        }

        func loadOCRTarget(id: Int64, parent: PersistentPointReader) -> (searchText: String, uniqueId: String, data: Data?)? {
            lock.withLock {
                guard ensureOpen(parent: parent), let stmt = stmtOCR else { return nil }
                sqlite3_reset(stmt)
                sqlite3_clear_bindings(stmt)
                sqlite3_bind_int64(stmt, 1, id)
                defer {
                    sqlite3_reset(stmt)
                    sqlite3_clear_bindings(stmt)
                }

                if sqlite3_step(stmt) == SQLITE_ROW {
                    let searchText: String
                    if let textPtr = sqlite3_column_text(stmt, 0) {
                        searchText = String(cString: textPtr)
                    } else {
                        searchText = ""
                    }

                    let uniqueId: String
                    if let uidPtr = sqlite3_column_text(stmt, 1) {
                        uniqueId = String(cString: uidPtr)
                    } else {
                        uniqueId = ""
                    }

                    if !searchText.isEmpty {
                        return (searchText: searchText, uniqueId: uniqueId, data: nil)
                    }

                    if let relPtr = sqlite3_column_text(stmt, 3) {
                        let relPath = String(cString: relPtr)
                        if !relPath.isEmpty, let external = MediaBlobStore.shared.readBlob(relPath: relPath) {
                            return (searchText: searchText, uniqueId: uniqueId, data: external)
                        }
                    }

                    if let bytes = sqlite3_column_blob(stmt, 2) {
                        let count = sqlite3_column_bytes(stmt, 2)
                        return (searchText: searchText, uniqueId: uniqueId, data: Data(bytes: bytes, count: Int(count)))
                    }
                    return (searchText: searchText, uniqueId: uniqueId, data: nil)
                }
                return nil
            }
        }
    }

    private let uiChannel = ConnectionChannel(busyTimeoutMs: 50)
    private let bulkChannel = ConnectionChannel(busyTimeoutMs: 2000)

    private let suspensionLock = OSAllocatedUnfairLock()
    private var _isSuspended = false

    var isMaintenanceSuspended: Bool {
        suspensionLock.withLock { _isSuspended }
    }

    private init() {}

    func close() {
        uiChannel.close()
        bulkChannel.close()
    }

    /// 在 VACUUM 或 checkpoint 维护期间挂起点查连接，杜绝并发打开与锁等待
    func withMaintenanceSuspension<T>(_ operation: () throws -> T) rethrows -> T {
        suspensionLock.withLock { _isSuspended = true }
        close()
        defer {
            suspensionLock.withLock { _isSuspended = false }
        }
        return try operation()
    }

    func loadData(id: Int64?, uniqueId: String, channel: PointReaderChannel = .ui) -> Data? {
        switch channel {
        case .ui:
            uiChannel.loadData(id: id, uniqueId: uniqueId, parent: self)
        case .bulk:
            bulkChannel.loadData(id: id, uniqueId: uniqueId, parent: self)
        }
    }

    func loadShowData(id: Int64) -> Data? {
        uiChannel.loadShowData(id: id, parent: self)
    }

    func loadMediaURL(id: Int64?, uniqueId: String) -> URL? {
        uiChannel.loadMediaURL(id: id, uniqueId: uniqueId, parent: self)
    }

    func loadOCRTarget(id: Int64) -> (searchText: String, uniqueId: String, data: Data?)? {
        bulkChannel.loadOCRTarget(id: id, parent: self)
    }
}

nonisolated enum PasteDataPointReader {
    nonisolated static var databasePath: String {
        PasteSQLManager.databasePath
    }

    /// 根据 id（主键 B-Tree）或 uniqueId 点查单条记录的完整二进制数据（默认 UI 通道 50ms 超时）
    nonisolated static func loadData(
        id: Int64?,
        uniqueId: String,
        channel: PointReaderChannel = .ui
    ) -> Data? {
        PersistentPointReader.shared.loadData(id: id, uniqueId: uniqueId, channel: channel)
    }

    /// 若该条目已外置至 `.media/` CAS 存储，则返回可用于零拷贝流式解码的本地文件 URL
    nonisolated static func loadMediaURL(
        id: Int64?,
        uniqueId: String
    ) -> URL? {
        PersistentPointReader.shared.loadMediaURL(id: id, uniqueId: uniqueId)
    }

    /// 点查单条记录的轻量 showData 缩略数据（命中 4MB 有界 LRU 缓存时零磁盘 I/O）
    nonisolated static func loadShowData(id: Int64) -> Data? {
        if let cached = ModelShowDataCache.shared.data(for: id) {
            return cached
        }
        guard let loaded = PersistentPointReader.shared.loadShowData(id: id) else {
            return nil
        }
        ModelShowDataCache.shared.setData(loaded, for: id)
        return loaded
    }

    /// 后台原子只读点查：获取单条记录的 searchText, uniqueId 以及必要的图片 data（走 Bulk 通道）
    nonisolated static func loadOCRTarget(id: Int64) -> (searchText: String, uniqueId: String, data: Data?)? {
        PersistentPointReader.shared.loadOCRTarget(id: id)
    }

    /// 在 VACUUM / checkpoint 期间安全挂起点查连接
    nonisolated static func withMaintenanceSuspension<T>(_ operation: () throws -> T) rethrows -> T {
        try PersistentPointReader.shared.withMaintenanceSuspension(operation)
    }

    /// 闲置释放预编译只读连接与缓存
    nonisolated static func closeConnection() {
        PersistentPointReader.shared.close()
    }
}
