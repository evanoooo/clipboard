//
//  SchemaMigrationTests.swift
//  Tests
//
//  Unit tests for SQLite Schema and Migrations in memory.
//

import Foundation
import SQLite

@MainActor
enum SchemaMigrationTests {
    static func run(runner: TestRunner.Type) {
        print("\n--- Testing Schema & Migration in Memory ---")

        do {
            let db = try MemoryDatabaseHelper.createInMemoryDatabase()

            // 1. Verify Clip table exists
            let tableCount = try db.scalar(
                "SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name='Clip'"
            ) as? Int64 ?? 0
            runner.assertEqual(tableCount, 1, "Clip table must exist")

            // 2. Verify columns exist via PRAGMA table_info
            let columns = try db.prepare("PRAGMA table_info(Clip)")
                .compactMap { $0[1] as? String }
            runner.assertTrue(columns.contains("id"), "id column must exist")
            runner.assertTrue(columns.contains("unique_id"), "unique_id column must exist")
            runner.assertTrue(columns.contains("sort_order"), "sort_order column must exist")
            runner.assertTrue(columns.contains("alias"), "alias column must exist")
            runner.assertTrue(columns.contains("alias_search"), "alias_search column must exist")
            runner.assertTrue(columns.contains("hidden"), "hidden column must exist")
            runner.assertTrue(columns.contains("group"), "group column must exist")

            // 3. Verify user_version read & update
            let v0 = try db.scalar("PRAGMA user_version") as? Int64 ?? 0
            runner.assertEqual(v0, 0, "Initial user_version should be 0")
            try db.run("PRAGMA user_version = 1")
            let v1 = try db.scalar("PRAGMA user_version") as? Int64 ?? 0
            runner.assertEqual(v1, 1, "user_version should update to 1")

            // 4. Verify unique constraint on unique_id
            let dummyData = "test".data(using: .utf8)!
            let insert1 = MemoryDatabaseHelper.clipTable.insert(
                Col.uniqueId <- "unique-123",
                Col.type <- "public.utf8-plain-text",
                Col.data <- dummyData,
                Col.timestamp <- 1000,
                Col.sortOrder <- 1,
                Col.appID <- 1,
                Col.searchText <- "test",
                Col.length <- 4,
                Col.group <- -1,
                Col.hidden <- 0
            )
            try db.run(insert1)

            var caughtConflict = false
            do {
                try db.run(insert1)
            } catch {
                caughtConflict = true
            }
            runner.assertTrue(caughtConflict, "Duplicate unique_id must trigger constraint error")

            print("✓ Schema & Migration tests passed!")
        } catch {
            print("❌ SchemaMigrationTests failed with error: \(error)")
            exit(1)
        }
    }
}
