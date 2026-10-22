//
//  StorageAnalysisTests.swift
//  Tests
//
//  Unit tests for storage breakdown, top consumer queries, and protection safety rules.
//

import Foundation
import SQLite

@MainActor
enum StorageAnalysisTests {
    static func run(runner: TestRunner.Type) {
        print("\n--- Testing Storage Analysis, Breakdown & Protection Safety ---")
        testProtectionRule(runner: runner)
        testStorageDiskUsageFormatting(runner: runner)
        testTypeBreakdownAndTopConsumersInMemory(runner: runner)
        testBulkDeleteAndReclaimSimulation(runner: runner)
        print("✓ Storage Analysis tests passed!")
    }

    private static func testProtectionRule(runner: TestRunner.Type) {
        // 1. group != -1 (加星或分类) 必须受保护
        let starredItem = StorageItemSummary(
            id: 1, uniqueId: "1", type: "image", timestamp: 1000,
            appID: 1, appName: "Safari", tag: nil, group: 1,
            byteSize: 10_000_000, summary: "Starred Photo"
        )
        runner.assertTrue(starredItem.isProtected, "Starred items (group > -1) must be protected")

        // 2. 带有自定义 tag 的必须受保护
        let taggedItem = StorageItemSummary(
            id: 2, uniqueId: "2", type: "rich", timestamp: 1000,
            appID: 1, appName: "Safari", tag: "Work", group: -1,
            byteSize: 5_000_000, summary: "Tagged Work Item"
        )
        runner.assertTrue(taggedItem.isProtected, "Tagged items must be protected")

        // 3. 既无 group 也无 tag 的普通项可以被勾选清理
        let regularItem = StorageItemSummary(
            id: 3, uniqueId: "3", type: "image", timestamp: 1000,
            appID: 1, appName: "Chrome", tag: nil, group: -1,
            byteSize: 8_000_000, summary: "Regular Screenshot"
        )
        runner.assertFalse(regularItem.isProtected, "Ordinary items must NOT be protected")
    }

    private static func testStorageDiskUsageFormatting(runner: TestRunner.Type) {
        let usage = StorageDiskUsage(
            mainDbBytes: 500 * 1024 * 1024,
            walBytes: 150 * 1024 * 1024,
            shmBytes: 32 * 1024,
            totalDiskBytes: 650 * 1024 * 1024,
            reclaimableFreeBytes: 130 * 1024 * 1024,
            totalItemCount: 13280
        )

        runner.assertEqual(usage.totalItemCount, 13280, "Total count matches")
        runner.assertTrue(usage.formattedTotalDisk.contains("MB") || usage.formattedTotalDisk.contains("GB"), "Total disk has unit")
        runner.assertTrue(usage.formattedReclaimable.contains("MB"), "Reclaimable has MB unit")
        runner.assertTrue(usage.reclaimableRatio > 0.19 && usage.reclaimableRatio < 0.21, "Reclaimable ratio around 20%")
    }

    private static func testTypeBreakdownAndTopConsumersInMemory(runner: TestRunner.Type) {
        let db = try! MemoryDatabaseHelper.createInMemoryDatabase()
        let table = Table("Clip")

        // 插入测试数据
        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
        let oldMs = nowMs - (40 * 24 * 60 * 60 * 1000) // 40天前

        let imgDataLarge = Data(repeating: 0xAA, count: 6 * 1024 * 1024) // 6MB
        let imgDataOld = Data(repeating: 0xBB, count: 3 * 1024 * 1024)   // 3MB
        let richData = Data(repeating: 0xCC, count: 2 * 1024 * 1024)     // 2MB
        let textData = Data("hello world".utf8)                          // ~11B

        // 1. 大图
        try! db.run(table.insert(
            Col.uniqueId <- "item-1", Col.type <- "image", Col.data <- imgDataLarge,
            Col.timestamp <- nowMs, Col.sortOrder <- 1, Col.appID <- 1,
            Col.searchText <- "Large screenshot", Col.length <- imgDataLarge.count,
            Col.group <- -1, Col.hidden <- 0
        ))

        // 2. 40天前的旧图 (未收藏)
        try! db.run(table.insert(
            Col.uniqueId <- "item-2", Col.type <- "image", Col.data <- imgDataOld,
            Col.timestamp <- oldMs, Col.sortOrder <- 2, Col.appID <- 1,
            Col.searchText <- "Old temporary capture", Col.length <- imgDataOld.count,
            Col.group <- -1, Col.hidden <- 0
        ))

        // 3. 大型富文本
        try! db.run(table.insert(
            Col.uniqueId <- "item-3", Col.type <- "rich", Col.data <- richData,
            Col.timestamp <- nowMs, Col.sortOrder <- 3, Col.appID <- 2,
            Col.searchText <- "Web page rich content", Col.length <- richData.count,
            Col.group <- -1, Col.hidden <- 0
        ))

        // 4. 小文本
        try! db.run(table.insert(
            Col.uniqueId <- "item-4", Col.type <- "string", Col.data <- textData,
            Col.timestamp <- nowMs, Col.sortOrder <- 4, Col.appID <- 1,
            Col.searchText <- "Small plain text", Col.length <- textData.count,
            Col.group <- -1, Col.hidden <- 0
        ))

        // 验证分组统计
        let stmt = try! db.prepare("SELECT type, count(*), sum(length(data)) FROM Clip GROUP BY type ORDER BY sum(length(data)) DESC")
        var typeRows: [(type: String, count: Int, bytes: Int64)] = []
        for row in stmt {
            typeRows.append((row[0] as! String, Int(row[1] as! Int64), row[2] as! Int64))
        }

        runner.assertEqual(typeRows.count, 3, "Three distinct types: image, rich, string")
        runner.assertEqual(typeRows[0].type, "image", "Images should take the most space")
        runner.assertEqual(typeRows[0].count, 2, "Two image records")
        runner.assertEqual(typeRows[0].bytes, Int64(9 * 1024 * 1024), "Total image bytes = 9MB")

        // 验证 Top 1 最大项为 item-1 (6MB)
        let topStmt = try! db.prepare("SELECT unique_id, length(data) FROM Clip ORDER BY length(data) DESC LIMIT 1")
        let firstRow = topStmt.makeIterator().next()!
        runner.assertEqual(firstRow[0] as! String, "item-1", "Top item should be item-1")
        runner.assertEqual(firstRow[1] as! Int64, Int64(6 * 1024 * 1024), "Top item byte size is 6MB")
    }

    private static func testBulkDeleteAndReclaimSimulation(runner: TestRunner.Type) {
        let db = try! MemoryDatabaseHelper.createInMemoryDatabase()
        let table = Table("Clip")
        let data1 = Data(repeating: 0x11, count: 4 * 1024 * 1024)
        let data2 = Data(repeating: 0x22, count: 2 * 1024 * 1024)

        try! db.run(table.insert(Col.uniqueId <- "u1", Col.type <- "image", Col.data <- data1, Col.timestamp <- 1000, Col.sortOrder <- 1, Col.appID <- 1, Col.searchText <- "one", Col.length <- 4096, Col.group <- -1, Col.hidden <- 0))
        let id2 = try! db.run(table.insert(Col.uniqueId <- "u2", Col.type <- "image", Col.data <- data2, Col.timestamp <- 1000, Col.sortOrder <- 2, Col.appID <- 1, Col.searchText <- "two", Col.length <- 2048, Col.group <- -1, Col.hidden <- 0))

        // 模拟批量清理选中的 id2 (2MB)
        let sumStmt = try! db.prepare("SELECT sum(length(data)) FROM Clip WHERE id = \(id2)")
        let freedBytes = (sumStmt.makeIterator().next()![0] as? Int64) ?? 0
        runner.assertEqual(freedBytes, Int64(2 * 1024 * 1024), "Freed bytes matches deleted item size")

        try! db.run(table.filter(Col.id == id2).delete())
        let countAfter = try! db.scalar(table.count)
        runner.assertEqual(countAfter, 1, "Only 1 item remains after deletion")
    }
}
