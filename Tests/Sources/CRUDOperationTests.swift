//
//  CRUDOperationTests.swift
//  Tests
//
//  Unit tests for SQLite CRUD operations in memory.
//

import Foundation
import SQLite

@MainActor
enum CRUDOperationTests {
    static func run(runner: TestRunner.Type) {
        print("\n--- Testing CRUD Operations in Memory ---")

        do {
            let db = try MemoryDatabaseHelper.createInMemoryDatabase()
            let table = MemoryDatabaseHelper.clipTable

            // 1. Insert & Verify
            let dummyData1 = "hello world".data(using: .utf8)!
            let insert1 = table.insert(
                Col.uniqueId <- "clip-uuid-1",
                Col.type <- "public.utf8-plain-text",
                Col.data <- dummyData1,
                Col.showData <- dummyData1,
                Col.timestamp <- 1000,
                Col.sortOrder <- 1,
                Col.appID <- 101,
                Col.searchText <- "helloworld",
                Col.length <- 11,
                Col.group <- -1,
                Col.alias <- "greeting",
                Col.aliasSearch <- "greeting",
                Col.hidden <- 0
            )
            let rowId1 = try db.run(insert1)
            runner.assertTrue(rowId1 > 0, "Insert should return valid row ID")

            let count1 = try db.scalar(table.count)
            runner.assertEqual(count1, 1, "Table count should be 1 after insertion")

            // 2. Query by ID
            let fetched = try db.pluck(table.filter(Col.id == rowId1))
            runner.assertTrue(fetched != nil, "Inserted record must be queryable")
            if let row = fetched {
                runner.assertEqual(row[Col.uniqueId], "clip-uuid-1", "unique_id mismatch")
                runner.assertEqual(row[Col.showData], dummyData1, "showData mismatch")
                runner.assertEqual(row[Col.alias], "greeting", "alias mismatch")
                runner.assertEqual(row[Col.hidden], 0, "hidden should be 0")
            }

            // 3. Batch Insert & Order by sort_order DESC
            for i in 2...5 {
                let text = "Item \(i)"
                let data = text.data(using: .utf8)!
                let insertI = table.insert(
                    Col.uniqueId <- "clip-uuid-\(i)",
                    Col.type <- "public.utf8-plain-text",
                    Col.data <- data,
                    Col.showData <- data,
                    Col.timestamp <- Int64(1000 + i * 10),
                    Col.sortOrder <- Int64(i),
                    Col.appID <- 101,
                    Col.searchText <- "item\(i)",
                    Col.length <- text.count,
                    Col.group <- -1,
                    Col.hidden <- 0
                )
                try db.run(insertI)
            }

            let sortedRows = try Array(db.prepare(table.order(Col.sortOrder.desc)))
            runner.assertEqual(sortedRows.count, 5, "Total count should be 5")
            runner.assertEqual(sortedRows.first?[Col.sortOrder], 5, "First item sort_order should be 5")
            runner.assertEqual(sortedRows.last?[Col.sortOrder], 1, "Last item sort_order should be 1")

            // 4. Update alias and alias_search
            let updateAlias = table.filter(Col.id == rowId1).update(
                Col.alias <- "super greeting",
                Col.aliasSearch <- "supergreeting"
            )
            let rowsUpdated = try db.run(updateAlias)
            runner.assertEqual(rowsUpdated, 1, "Should update exactly 1 row")

            let updatedRow = try db.pluck(table.filter(Col.id == rowId1))
            runner.assertEqual(updatedRow?[Col.alias], "super greeting", "Updated alias mismatch")
            runner.assertEqual(updatedRow?[Col.aliasSearch], "supergreeting", "Updated aliasSearch mismatch")

            // 5. Hide / Unhide filtering
            let hideQuery = table.filter(Col.id == rowId1).update(Col.hidden <- 1)
            try db.run(hideQuery)

            let visibleCount = try db.scalar(table.filter(Col.hidden == 0).count)
            runner.assertEqual(visibleCount, 4, "Visible count should be 4 after hiding 1 item")

            let hiddenCount = try db.scalar(table.filter(Col.hidden == 1).count)
            runner.assertEqual(hiddenCount, 1, "Hidden count should be 1")

            // 6. Group assignment & filtering
            let groupQuery = table.filter(Col.sortOrder == 2).update(Col.group <- 42)
            try db.run(groupQuery)

            let group42Count = try db.scalar(table.filter(Col.group == 42).count)
            runner.assertEqual(group42Count, 1, "Group 42 count should be 1")

            // 7. Delete record
            let deleteQuery = table.filter(Col.id == rowId1).delete()
            let deletedCount = try db.run(deleteQuery)
            runner.assertEqual(deletedCount, 1, "Should delete exactly 1 row")

            let remainingTotal = try db.scalar(table.count)
            runner.assertEqual(remainingTotal, 4, "Total count should be 4 after deletion")

            print("✓ CRUD operations tests passed!")
        } catch {
            print("❌ CRUDOperationTests failed with error: \(error)")
            exit(1)
        }
    }
}
