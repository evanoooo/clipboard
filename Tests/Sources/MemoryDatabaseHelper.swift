//
//  MemoryDatabaseHelper.swift
//  Tests
//
//  In-memory SQLite test database helper.
//

import Foundation
import SQLite

enum MemoryDatabaseHelper {
    static let clipTable = Table("Clip")

    static func createInMemoryDatabase() throws -> Connection {
        let db = try Connection(.inMemory)
        db.busyTimeout = 5.0

        // Create main Clip table
        let statement = clipTable.create(ifNotExists: true) { schema in
            schema.column(Col.id, primaryKey: true)
            schema.column(Col.uniqueId)
            schema.column(Col.type)
            schema.column(Col.data)
            schema.column(Col.showData)
            schema.column(Col.timestamp)
            schema.column(Col.appID)
            schema.column(Col.searchText)
            schema.column(Col.length)
            schema.column(Col.group, defaultValue: -1)
            schema.column(Col.tag)
            schema.column(Col.alias)
            schema.column(Col.aliasSearch)
            schema.column(Col.hidden, defaultValue: 0)
        }
        try db.run(statement)

        // Run migrations
        try PasteOrder.setup(on: db)
        try PasteAliasMigration.setup(on: db)
        try PasteFTSMigration.setup(on: db)
        try SourceAppSQL.create(on: db)

        // Create core indexes
        try db.run("CREATE UNIQUE INDEX IF NOT EXISTS uidx_unique_id ON Clip(unique_id)")
        try db.run("CREATE INDEX IF NOT EXISTS idx_hidden_ts ON Clip(hidden, timestamp DESC)")
        try db.run("CREATE INDEX IF NOT EXISTS idx_group_ts ON Clip(\"group\", timestamp DESC)")
        try db.run("CREATE INDEX IF NOT EXISTS idx_app_hidden_ts ON Clip(app_id, hidden, timestamp DESC)")

        return db
    }
}
