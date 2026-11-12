//
//  PasteDataPointReader.swift
//  Clipboard
//
//  按需点查 Col.data，提供 ~0.002ms 极限零锁点查，消除搜索/列表对大 Payload 的预载开销。
//

import Foundation
import os
import SQLite3

nonisolated(unsafe) private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

nonisolated final class PersistentPointReader: @unchecked Sendable {
    static let shared = PersistentPointReader()

    private let lock = OSAllocatedUnfairLock()
    private var db: OpaquePointer?
    private var stmtById: OpaquePointer?
    private var stmtByUniqueId: OpaquePointer?
    private var stmtOCR: OpaquePointer?
    private var stmtShowData: OpaquePointer?

    private init() {}

    private func ensureOpen() -> Bool {
        if db != nil { return true }
        guard sqlite3_open_v2(PasteSQLManager.databasePath, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK else {
            db = nil
            return false
        }
        sqlite3_busy_timeout(db, 5000)
        sqlite3_exec(db, "PRAGMA cache_size = -512;", nil, nil, nil)
        let mmapBytes = Int64(PasteUserDefaults.sqliteMmapSizeMB) * 1024 * 1024
        sqlite3_exec(db, "PRAGMA mmap_size = \(mmapBytes);", nil, nil, nil)

        let sqlById = "SELECT data FROM Clip WHERE id = ? LIMIT 1"
        sqlite3_prepare_v2(db, sqlById, -1, &stmtById, nil)

        let sqlByUniqueId = "SELECT data FROM Clip WHERE unique_id = ? LIMIT 1"
        sqlite3_prepare_v2(db, sqlByUniqueId, -1, &stmtByUniqueId, nil)

        let sqlOCR = "SELECT search_text, unique_id, data FROM Clip WHERE id = ? LIMIT 1"
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

    func loadData(id: Int64?, uniqueId: String) -> Data? {
        lock.withLock {
            guard ensureOpen() else { return nil }
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
                if let bytes = sqlite3_column_blob(stmt, 0) {
                    let count = sqlite3_column_bytes(stmt, 0)
                    return Data(bytes: bytes, count: Int(count))
                }
            }
            return nil
        }
    }

    func loadShowData(id: Int64) -> Data? {
        lock.withLock {
            guard ensureOpen(), let stmt = stmtShowData else { return nil }
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

    func loadOCRTarget(id: Int64) -> (searchText: String, uniqueId: String, data: Data?)? {
        lock.withLock {
            guard ensureOpen(), let stmt = stmtOCR else { return nil }
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

nonisolated enum PasteDataPointReader {
    nonisolated static var databasePath: String {
        PasteSQLManager.databasePath
    }

    /// 根据 id（主键 B-Tree）或 uniqueId 点查单条记录的完整二进制数据（复用预编译语句与只读句柄）
    nonisolated static func loadData(id: Int64?, uniqueId: String) -> Data? {
        PersistentPointReader.shared.loadData(id: id, uniqueId: uniqueId)
    }

    /// 点查单条记录的轻量 showData 缩略数据
    nonisolated static func loadShowData(id: Int64) -> Data? {
        PersistentPointReader.shared.loadShowData(id: id)
    }

    /// 单连接原子只读点查：获取单条记录的 searchText, uniqueId 以及必要的图片 data
    nonisolated static func loadOCRTarget(id: Int64) -> (searchText: String, uniqueId: String, data: Data?)? {
        PersistentPointReader.shared.loadOCRTarget(id: id)
    }

    /// 闲置释放预编译只读连接与缓存
    nonisolated static func closeConnection() {
        PersistentPointReader.shared.close()
    }
}
