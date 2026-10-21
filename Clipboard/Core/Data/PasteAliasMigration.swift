import Foundation
import SQLite

/// 别名为后加列：旧库按列存在性幂等补齐，不依赖 `PRAGMA user_version`。
enum PasteAliasMigration {
    nonisolated static func setup(on database: Connection) throws {
        try database.transaction(.immediate) {
            let columns = try database.prepare("PRAGMA table_info(Clip)")
                .compactMap { $0[1] as? String }
            if !columns.contains("alias") {
                try database.run("ALTER TABLE Clip ADD COLUMN alias TEXT")
            }
            if !columns.contains("alias_search") {
                try database.run("ALTER TABLE Clip ADD COLUMN alias_search TEXT")
            }
        }
    }
}
