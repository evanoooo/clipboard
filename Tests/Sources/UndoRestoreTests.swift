//
//  UndoRestoreTests.swift
//  Tests
//
//  Unit tests for Undo/Restore operations & transactional integrity.
//

import Foundation
import SQLite

@MainActor
enum UndoRestoreTests {
    static func run(runner: TestRunner.Type) {
        print("\n--- Testing Undo/Restore & Transactions in Memory ---")

        do {
            let db = try MemoryDatabaseHelper.createInMemoryDatabase()
            let table = MemoryDatabaseHelper.clipTable

            // 1. Prepare initial dataset
            let originalId: Int64 = 999
            let originalUniqueId = "undo-target-uuid"
            let originalSortOrder: Int64 = 88
            let originalText = "restore me please"
            let originalData = originalText.data(using: .utf8)!

            let insertTarget = table.insert(
                Col.id <- originalId,
                Col.uniqueId <- originalUniqueId,
                Col.type <- "public.utf8-plain-text",
                Col.data <- originalData,
                Col.showData <- originalData,
                Col.timestamp <- 5000,
                Col.sortOrder <- originalSortOrder,
                Col.appID <- 200,
                Col.searchText <- "restoremeplease",
                Col.length <- originalText.count,
                Col.group <- -1,
                Col.alias <- "restore_target",
                Col.aliasSearch <- "restoretarget",
                Col.hidden <- 0
            )
            try db.run(insertTarget)

            // Capture snapshot of the record before deletion
            guard let snapshot = try db.pluck(table.filter(Col.id == originalId)) else {
                runner.assertTrue(false, "Failed to pluck initial record for snapshot")
                return
            }

            let snapId = snapshot[Col.id]
            let snapUniqueId = snapshot[Col.uniqueId]
            let snapType = snapshot[Col.type]
            let snapData = snapshot[Col.data]
            let snapShowData = snapshot[Col.showData]
            let snapTimestamp = snapshot[Col.timestamp]
            let snapSortOrder = snapshot[Col.sortOrder]
            let snapAppID = snapshot[Col.appID]
            let snapSearchText = snapshot[Col.searchText]
            let snapLength = snapshot[Col.length]
            let snapGroup = snapshot[Col.group]
            let snapAlias = snapshot[Col.alias]
            let snapAliasSearch = snapshot[Col.aliasSearch]
            let snapHidden = snapshot[Col.hidden]

            // 2. Perform deletion
            try db.run(table.filter(Col.id == originalId).delete())
            let countAfterDelete = try db.scalar(table.filter(Col.id == originalId).count)
            runner.assertEqual(countAfterDelete, 0, "Record must be deleted")

            // 3. Restore from snapshot with original ID & sortOrder inside a transaction
            try db.transaction(.immediate) {
                let restoreInsert = table.insert(
                    Col.id <- snapId,
                    Col.uniqueId <- snapUniqueId,
                    Col.type <- snapType,
                    Col.data <- snapData,
                    Col.showData <- snapShowData,
                    Col.timestamp <- snapTimestamp,
                    Col.sortOrder <- snapSortOrder,
                    Col.appID <- snapAppID,
                    Col.searchText <- snapSearchText,
                    Col.length <- snapLength,
                    Col.group <- snapGroup,
                    Col.alias <- snapAlias,
                    Col.aliasSearch <- snapAliasSearch,
                    Col.hidden <- snapHidden
                )
                try db.run(restoreInsert)
            }

            // 4. Verify restored record matches original exactly
            let restored = try db.pluck(table.filter(Col.id == originalId))
            runner.assertTrue(restored != nil, "Restored record must exist")
            if let row = restored {
                runner.assertEqual(row[Col.id], originalId, "Restored ID mismatch")
                runner.assertEqual(row[Col.uniqueId], originalUniqueId, "Restored unique_id mismatch")
                runner.assertEqual(row[Col.sortOrder], originalSortOrder, "Restored sort_order mismatch")
                runner.assertEqual(row[Col.showData], originalData, "Restored showData mismatch")
                runner.assertEqual(row[Col.alias], "restore_target", "Restored alias mismatch")
            }

            // 5. Test Transaction Rollback integrity
            let countBeforeTx = try db.scalar(table.count)
            var rollbackTriggered = false
            do {
                try db.transaction(.immediate) {
                    try db.run(table.insert(
                        Col.uniqueId <- "tx-temp-1",
                        Col.type <- "text",
                        Col.data <- Data(),
                        Col.timestamp <- 1,
                        Col.sortOrder <- 100,
                        Col.appID <- 1,
                        Col.searchText <- "temp",
                        Col.length <- 0,
                        Col.group <- -1,
                        Col.hidden <- 0
                    ))

                    // Intentionally throw error to trigger rollback
                    struct TxTestError: Error {}
                    throw TxTestError()
                }
            } catch {
                rollbackTriggered = true
            }

            runner.assertTrue(rollbackTriggered, "Transaction error should have thrown")
            let countAfterRollback = try db.scalar(table.count)
            runner.assertEqual(countAfterRollback, countBeforeTx, "Table row count must not change after rolled-back transaction")

            print("✓ Undo/Restore & Transaction tests passed!")
        } catch {
            print("❌ UndoRestoreTests failed with error: \(error)")
            exit(1)
        }
    }
}
