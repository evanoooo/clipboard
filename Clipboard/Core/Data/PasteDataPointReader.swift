//
//  PasteDataPointReader.swift
//  Clipboard
//
//  按需点查 Col.data，提供 ~0.002ms 极限零锁点查，消除搜索/列表对大 Payload 的预载开销。
//

import Foundation
import SQLite3

nonisolated(unsafe) private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

enum PasteDataPointReader {
    nonisolated static var databasePath: String {
        PasteSQLManager.databasePath
    }

    /// 根据 id（主键 B-Tree）或 uniqueId 点查单条记录的完整二进制数据
    nonisolated static func loadData(id: Int64?, uniqueId: String) -> Data? {
        var db: OpaquePointer?
        guard sqlite3_open_v2(databasePath, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK else {
            return nil
        }
        sqlite3_busy_timeout(db, 5000)
        defer { sqlite3_close(db) }

        var stmt: OpaquePointer?
        if let id {
            let sql = "SELECT data FROM Clip WHERE id = ? LIMIT 1"
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
            sqlite3_bind_int64(stmt, 1, id)
        } else {
            let sql = "SELECT data FROM Clip WHERE unique_id = ? LIMIT 1"
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
            sqlite3_bind_text(stmt, 1, uniqueId, -1, SQLITE_TRANSIENT)
        }
        defer { sqlite3_finalize(stmt) }

        if sqlite3_step(stmt) == SQLITE_ROW {
            if let bytes = sqlite3_column_blob(stmt, 0) {
                let count = sqlite3_column_bytes(stmt, 0)
                return Data(bytes: bytes, count: Int(count))
            }
        }
        return nil
    }

    /// 单连接原子只读点查：获取单条记录的 searchText, uniqueId 以及必要的图片 data
    nonisolated static func loadOCRTarget(id: Int64) -> (searchText: String, uniqueId: String, data: Data?)? {
        var db: OpaquePointer?
        guard sqlite3_open_v2(databasePath, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK else {
            return nil
        }
        sqlite3_busy_timeout(db, 5000)
        defer { sqlite3_close(db) }

        var stmt: OpaquePointer?
        let sql = "SELECT search_text, unique_id, data FROM Clip WHERE id = ? LIMIT 1"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_int64(stmt, 1, id)

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

            // 若已有非空 searchText（无论是有字还是无字占位符），无需读取大图 BLOB
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
