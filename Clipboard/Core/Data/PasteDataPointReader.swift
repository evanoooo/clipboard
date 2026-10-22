//
//  PasteDataPointReader.swift
//  Clipboard
//
//  按需点查 Col.data，提供 ~0.002ms 极限零锁点查，消除搜索/列表对大 Payload 的预载开销。
//

import Foundation
import SQLite3

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
        defer { sqlite3_close(db) }

        var stmt: OpaquePointer?
        if let id {
            let sql = "SELECT data FROM Clip WHERE id = ? LIMIT 1"
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
            sqlite3_bind_int64(stmt, 1, id)
        } else {
            let sql = "SELECT data FROM Clip WHERE unique_id = ? LIMIT 1"
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
            sqlite3_bind_text(stmt, 1, (uniqueId as NSString).utf8String, -1, nil)
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
}
