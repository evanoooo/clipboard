//
//  FTSTriggerTests.swift
//  Tests
//
//  Unit tests for SQLite FTS5 Virtual Table and Synchronizing Triggers.
//

import Foundation
import SQLite

@MainActor
enum FTSTriggerTests {
    static func run(runner: TestRunner.Type) {
        print("\n--- Testing FTS5 Virtual Table & Triggers ---")

        do {
            let db = try MemoryDatabaseHelper.createInMemoryDatabase()
            let table = MemoryDatabaseHelper.clipTable

            // 1. Verify clip_fts virtual table exists
            let ftsTableCount = try db.scalar(
                "SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name='clip_fts'"
            ) as? Int64 ?? 0
            runner.assertEqual(ftsTableCount, 1, "clip_fts virtual table must exist")

            // 2. Test INSERT trigger (clip_ai)
            let text1 = "func calculateTotal() -> Int"
            let data1 = text1.data(using: .utf8)!
            let insert1 = table.insert(
                Col.id <- 101,
                Col.uniqueId <- "fts-uuid-1",
                Col.type <- "public.utf8-plain-text",
                Col.data <- data1,
                Col.showData <- data1,
                Col.timestamp <- 1000,
                Col.sortOrder <- 10,
                Col.appID <- 1,
                Col.searchText <- "funccalculatetotalint",
                Col.length <- text1.count,
                Col.group <- -1,
                Col.alias <- "math_func",
                Col.aliasSearch <- "mathfunc",
                Col.hidden <- 0
            )
            try db.run(insert1)

            // Query FTS directly by token in searchText
            let matchSearchText = try db.scalar(
                "SELECT COUNT(*) FROM clip_fts WHERE clip_fts MATCH '\"total\"'"
            ) as? Int64 ?? 0
            runner.assertEqual(matchSearchText, 1, "FTS5 should match 'total' in search_text")

            // Query FTS by token in aliasSearch
            let matchAlias = try db.scalar(
                "SELECT COUNT(*) FROM clip_fts WHERE clip_fts MATCH '\"math\"'"
            ) as? Int64 ?? 0
            runner.assertEqual(matchAlias, 1, "FTS5 should match 'math' in alias_search")

            // Cross-column AND query
            let matchCross = try db.scalar(
                "SELECT COUNT(*) FROM clip_fts WHERE clip_fts MATCH '\"func\" AND \"math\"'"
            ) as? Int64 ?? 0
            runner.assertEqual(matchCross, 1, "FTS5 should match across search_text and alias_search")

            // 3. Test Chinese / CJK Substring matching
            let text2 = "我的剪贴板历史记录测试"
            let data2 = text2.data(using: .utf8)!
            let insert2 = table.insert(
                Col.id <- 102,
                Col.uniqueId <- "fts-uuid-2",
                Col.type <- "public.utf8-plain-text",
                Col.data <- data2,
                Col.showData <- data2,
                Col.timestamp <- 2000,
                Col.sortOrder <- 20,
                Col.appID <- 1,
                Col.searchText <- "我的剪贴板历史记录测试",
                Col.length <- text2.count,
                Col.group <- -1,
                Col.hidden <- 0
            )
            try db.run(insert2)

            let matchChinese1 = try db.scalar(
                "SELECT COUNT(*) FROM clip_fts WHERE clip_fts MATCH '\"剪贴板\"'"
            ) as? Int64 ?? 0
            runner.assertEqual(matchChinese1, 1, "FTS5 trigram should match 3-char Chinese '剪贴板'")

            let matchChinese2 = try db.scalar(
                "SELECT COUNT(*) FROM clip_fts WHERE clip_fts MATCH '\"历史记录\"'"
            ) as? Int64 ?? 0
            runner.assertEqual(matchChinese2, 1, "FTS5 trigram should match 4-char Chinese '历史记录'")

            // 4. Test UPDATE trigger (clip_au)
            let updateQuery = table.filter(Col.id == 101).update(
                Col.alias <- "financial_ledger",
                Col.aliasSearch <- "financialledger"
            )
            try db.run(updateQuery)

            let matchOldAlias = try db.scalar(
                "SELECT COUNT(*) FROM clip_fts WHERE clip_fts MATCH '\"math\"'"
            ) as? Int64 ?? 0
            runner.assertEqual(matchOldAlias, 0, "Old alias must no longer match after update")

            let matchNewAlias = try db.scalar(
                "SELECT COUNT(*) FROM clip_fts WHERE clip_fts MATCH '\"financial\"'"
            ) as? Int64 ?? 0
            runner.assertEqual(matchNewAlias, 1, "New alias must match after update")

            // 5. Test DELETE trigger (clip_ad)
            let deleteQuery = table.filter(Col.id == 101).delete()
            try db.run(deleteQuery)

            let matchDeleted = try db.scalar(
                "SELECT COUNT(*) FROM clip_fts WHERE clip_fts MATCH '\"calculate\"'"
            ) as? Int64 ?? 0
            runner.assertEqual(matchDeleted, 0, "Deleted item must not match in FTS5")

            // 6. Test JOIN query with filters and sorting
            let insert3 = table.insert(
                Col.id <- 103,
                Col.uniqueId <- "fts-uuid-3",
                Col.type <- "public.utf8-plain-text",
                Col.data <- "swift programming".data(using: .utf8)!,
                Col.showData <- "swift programming".data(using: .utf8)!,
                Col.timestamp <- 3000,
                Col.sortOrder <- 30,
                Col.appID <- 1,
                Col.searchText <- "swiftprogramming",
                Col.length <- 17,
                Col.group <- -1,
                Col.hidden <- 0
            )
            try db.run(insert3)

            let insert4Hidden = table.insert(
                Col.id <- 104,
                Col.uniqueId <- "fts-uuid-4",
                Col.type <- "public.utf8-plain-text",
                Col.data <- "swift hidden item".data(using: .utf8)!,
                Col.showData <- "swift hidden item".data(using: .utf8)!,
                Col.timestamp <- 4000,
                Col.sortOrder <- 40,
                Col.appID <- 1,
                Col.searchText <- "swifthiddenitem",
                Col.length <- 17,
                Col.group <- -1,
                Col.hidden <- 1 // Hidden
            )
            try db.run(insert4Hidden)

            let joinSQL = """
                SELECT Clip.id, Clip.sort_order
                FROM Clip
                JOIN clip_fts ON Clip.id = clip_fts.rowid
                WHERE clip_fts MATCH '\"swift\"'
                  AND Clip.hidden = 0
                ORDER BY Clip.sort_order DESC;
            """
            let rows = try db.prepare(joinSQL).map { $0 }
            runner.assertEqual(rows.count, 1, "Only non-hidden swift item should return")
            runner.assertEqual(rows.first?[0] as? Int64, 103, "Returned row ID should be 103")

            // 7. Test DSL subquery integration
            let matchExpr = Expression<Bool>(
                "id IN (SELECT rowid FROM clip_fts WHERE clip_fts MATCH ?)",
                ["\"swift\""]
            )
            let ftsFiltered = try db.prepare(table.filter(matchExpr && Col.hidden == 0)).map { $0 }
            runner.assertEqual(ftsFiltered.count, 1, "Filter DSL with FTS subquery must return 1 item")
            runner.assertEqual(ftsFiltered.first?[Col.id], 103, "Returned ID must be 103")

            // 8. Test short token (<3 chars) LIKE fallback
            let shortPattern = "%sw%"
            let likeFiltered = try db.prepare(table.filter((Col.searchText.like(shortPattern)) && Col.hidden == 0)).map { $0 }
            runner.assertEqual(likeFiltered.count, 1, "LIKE fallback should also work correctly")

            print("✓ FTS5 Virtual Table & Triggers tests passed!")
        } catch {
            print("❌ FTSTriggerTests failed with error: \(error)")
            exit(1)
        }
    }
}
