//
//  StorageAnalysisTests.swift
//  Tests
//
//  Unit tests for storage breakdown, top consumer queries, and protection safety rules.
//

import AppKit
import Foundation
import SQLite
import SwiftUI

@MainActor
enum StorageAnalysisTests {
    static func run(runner: TestRunner.Type) {
        print("\n--- Testing Storage Analysis, Breakdown & Protection Safety ---")
        testProtectionRule(runner: runner)
        testStorageDiskUsageFormatting(runner: runner)
        testPresetFilterOptionsAndTimestampLogic(runner: runner)
        testTypeBreakdownAndTopConsumersInMemory(runner: runner)
        testBulkDeleteAndReclaimSimulation(runner: runner)
        testSoftQuotaAndAgingPolicy(runner: runner)
        testMmapThresholds(runner: runner)
        testClipStorageQueries(runner: runner)
        print("✓ Storage Analysis tests passed!")
    }

    private static func testMmapThresholds(runner: TestRunner.Type) {
        runner.assertEqual(SQLiteMmapThreshold.disabled.rawValue, 0, "Disabled should be 0")
        runner.assertEqual(SQLiteMmapThreshold.disabled.bytes, 0, "Disabled bytes should be 0")
        runner.assertEqual(SQLiteMmapThreshold.mb128.rawValue, 128, "Recommended should be 128")
        runner.assertEqual(SQLiteMmapThreshold.mb128.bytes, 128 * 1024 * 1024, "128MB bytes check")
        runner.assertTrue(SQLiteMmapThreshold.allCases.contains(.disabled), "Should contain disabled")
        runner.assertTrue(SQLiteMmapThreshold.allCases.contains(.mb128), "Should contain 128MB")
    }

    private static func testProtectionRule(runner: TestRunner.Type) {
        // 1. group != -1 (加星或分类) 必须受保护
        let starredItem = StorageItemSummary(
            id: 1, uniqueId: "1", type: "image", timestamp: 1000,
            appID: 1, appName: "Safari", tag: "image", group: 1,
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

        // 3. 既无 group 也无自定义 tag（标准 tag 如 image）的普通项可以被勾选清理
        let regularItem = StorageItemSummary(
            id: 3, uniqueId: "3", type: "image", timestamp: 1000,
            appID: 1, appName: "Chrome", tag: "image", group: -1,
            byteSize: 8_000_000, summary: "Regular Screenshot"
        )
        runner.assertFalse(regularItem.isProtected, "Ordinary items must NOT be protected even if tag is 'image'")
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

    private static func testPresetFilterOptionsAndTimestampLogic(runner: TestRunner.Type) {
        runner.assertEqual(StoragePresetFilter.allCases.count, 6, "Preset filters have 6 cases")
        runner.assertTrue(StoragePresetFilter.allCases.contains(.oneMonthUnstarredImages), "Contains 1 month filter")
        runner.assertTrue(StoragePresetFilter.allCases.contains(.threeMonthsUnstarredImages), "Contains 3 months filter")
        runner.assertTrue(StoragePresetFilter.allCases.contains(.sixMonthsUnstarredImages), "Contains 6 months filter")

        let nowSec = Int64(1792657754) // ~2026-10-22
        let threeDaysAgoSec = nowSec - (3 * 86400) // ~2026-10-19
        let thirtyDaysAgoSec = nowSec - (30 * 86400) // ~2026-09-22
        let ninetyDaysAgoSec = nowSec - (90 * 86400) // ~2026-07-24

        // 验证 3 天前的时间戳绝不能被判定为 30 天前
        let is30DaysOld = threeDaysAgoSec < thirtyDaysAgoSec
        runner.assertFalse(is30DaysOld, "3-day old item must NOT be classified as 30-day old")

        // 验证 30 天前的时间戳
        let fortyDaysAgoSec = nowSec - (40 * 86400)
        runner.assertTrue(fortyDaysAgoSec < thirtyDaysAgoSec, "40-day old item matches 30-day filter")
        runner.assertFalse(fortyDaysAgoSec < ninetyDaysAgoSec, "40-day old item does NOT match 90-day filter")

        let hundredDaysAgoSec = nowSec - (100 * 86400)
        runner.assertTrue(hundredDaysAgoSec < ninetyDaysAgoSec, "100-day old item matches 90-day filter")
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

    private static func testSoftQuotaAndAgingPolicy(runner: TestRunner.Type) {
        // 1. 阈值与策略枚举属性检查（标准十进制，严格与 macOS ByteCountFormatter .file 对齐）
        runner.assertEqual(SoftQuotaThreshold.mb500.rawValue, 500_000_000, "500MB = 500000000 bytes")
        runner.assertEqual(SoftQuotaThreshold.gb1.rawValue, 1_000_000_000, "1GB = 1000000000 bytes")
        runner.assertEqual(SoftQuotaThreshold.gb2.rawValue, 2_000_000_000, "2GB = 2000000000 bytes")
        runner.assertEqual(SoftQuotaThreshold.unlimited.rawValue, 0, "Unlimited = 0")

        runner.assertEqual(SoftQuotaAgingPolicy.oneMonth.days, 30, "oneMonth = 30 days")
        runner.assertEqual(SoftQuotaAgingPolicy.threeMonths.days, 90, "threeMonths = 90 days")
        runner.assertEqual(SoftQuotaAgingPolicy.sixMonths.days, 180, "sixMonths = 180 days")

        // 2. StorageQuotaStatus 警戒状态判定
        let healthyStatus = StorageQuotaStatus(
            currentBytes: 300_000_000,
            quotaBytes: 500_000_000,
            candidateItemCount: 10,
            candidateFreedBytes: 50_000_000
        )
        runner.assertTrue(healthyStatus.isEnabled, "Healthy quota is enabled")
        runner.assertFalse(healthyStatus.isExceeded, "Healthy quota is not exceeded")
        runner.assertFalse(healthyStatus.isWarning, "Healthy quota ratio is 0.6, not warning")
        runner.assertTrue(healthyStatus.ratio > 0.59 && healthyStatus.ratio < 0.61, "Ratio is ~0.6")

        let warningStatus = StorageQuotaStatus(
            currentBytes: 460_000_000,
            quotaBytes: 500_000_000,
            candidateItemCount: 15,
            candidateFreedBytes: 80_000_000
        )
        runner.assertTrue(warningStatus.isWarning, "460MB/500MB = 92% >= 85%, should be warning")
        runner.assertFalse(warningStatus.isExceeded, "Not exceeded yet")

        let exceededStatus = StorageQuotaStatus(
            currentBytes: 600_000_000,
            quotaBytes: 500_000_000,
            candidateItemCount: 20,
            candidateFreedBytes: 120_000_000
        )
        runner.assertTrue(exceededStatus.isExceeded, "600MB >= 500MB is exceeded")
        runner.assertTrue(exceededStatus.isWarning, "Exceeded is also warning")

        let unlimitedStatus = StorageQuotaStatus(
            currentBytes: 600_000_000,
            quotaBytes: 0,
            candidateItemCount: 0,
            candidateFreedBytes: 0
        )
        runner.assertFalse(unlimitedStatus.isEnabled, "Quota 0 means unlimited / disabled")
        runner.assertFalse(unlimitedStatus.isExceeded, "Unlimited is never exceeded")
        runner.assertEqual(unlimitedStatus.ratio, 0.0, "Unlimited ratio is 0")

        // 3. 淘汰候选与安全豁免规则模拟
        let db = try! MemoryDatabaseHelper.createInMemoryDatabase()
        let table = Table("Clip")
        let nowSec = Int64(Date().timeIntervalSince1970)
        let oldSec100Days = nowSec - (100 * 86400) // 100 天前
        let recentSec10Days = nowSec - (10 * 86400) // 10 天前

        let imgData = Data(repeating: 0x88, count: 2 * 1024 * 1024) // 2MB
        let textData = Data("Important plain text".utf8)

        // A. 100天前已加星收藏的图片 (group = 1) -> 必须豁免！
        try! db.run(table.insert(
            Col.uniqueId <- "c-starred", Col.type <- "image", Col.data <- imgData,
            Col.timestamp <- oldSec100Days, Col.sortOrder <- 1, Col.appID <- 1,
            Col.searchText <- "Starred image", Col.length <- imgData.count,
            Col.group <- 1, Col.hidden <- 0, Col.tag <- "image"
        ))

        // B. 100天前带有自定义标签的图片 (tag = "Design", group = -1) -> 必须豁免！
        try! db.run(table.insert(
            Col.uniqueId <- "c-tagged", Col.type <- "image", Col.data <- imgData,
            Col.timestamp <- oldSec100Days, Col.sortOrder <- 2, Col.appID <- 1,
            Col.searchText <- "Tagged image", Col.length <- imgData.count,
            Col.group <- -1, Col.hidden <- 0, Col.tag <- "Design"
        ))

        // C. 100天前的纯文本 (tag = "string", group = -1) -> 豁免，纯文本不淘汰！
        try! db.run(table.insert(
            Col.uniqueId <- "c-text", Col.type <- "string", Col.data <- textData,
            Col.timestamp <- oldSec100Days, Col.sortOrder <- 3, Col.appID <- 1,
            Col.searchText <- "Old text", Col.length <- textData.count,
            Col.group <- -1, Col.hidden <- 0, Col.tag <- "string"
        ))

        // D. 10天前最近的普通图片 (tag = "image", group = -1) -> 豁免，未超过90天！
        try! db.run(table.insert(
            Col.uniqueId <- "c-recent-img", Col.type <- "image", Col.data <- imgData,
            Col.timestamp <- recentSec10Days, Col.sortOrder <- 4, Col.appID <- 1,
            Col.searchText <- "Recent image", Col.length <- imgData.count,
            Col.group <- -1, Col.hidden <- 0, Col.tag <- "image"
        ))

        // E. 100天前未收藏的临时图片 (tag = "image", group = -1) -> 符合淘汰条件！
        try! db.run(table.insert(
            Col.uniqueId <- "c-evictable-img", Col.type <- "image", Col.data <- imgData,
            Col.timestamp <- oldSec100Days, Col.sortOrder <- 5, Col.appID <- 1,
            Col.searchText <- "Old temporary image", Col.length <- imgData.count,
            Col.group <- -1, Col.hidden <- 0, Col.tag <- "image"
        ))

        // 运行 SQL 模拟 90 天老化淘汰策略筛选
        let cutoff90DaysSec = nowSec - (90 * 86400)
        let candidateQuery = """
            SELECT id, unique_id, length(data) FROM Clip
            WHERE (`group` IS NULL OR `group` = -1)
              AND (tag IS NULL OR tag = '' OR lower(tag) IN ('image', 'rich', 'string', 'file', 'link', 'color', 'unknown'))
              AND (lower(type) LIKE '%image%' OR lower(type) LIKE '%png%' OR lower(type) LIKE '%tiff%' OR lower(type) LIKE '%jpeg%' OR lower(type) LIKE '%jpg%')
              AND ((CASE WHEN timestamp > 10000000000 THEN timestamp / 1000 ELSE timestamp END) < \(cutoff90DaysSec))
            ORDER BY timestamp ASC
        """

        let candidateRows = try! db.prepare(candidateQuery)
        var candidates: [(id: Int64, uid: String, bytes: Int64)] = []
        for r in candidateRows {
            candidates.append((r[0] as! Int64, r[1] as! String, r[2] as! Int64))
        }

        runner.assertEqual(candidates.count, 1, "Only c-evictable-img should match eviction criteria")
        runner.assertEqual(candidates.first?.uid, "c-evictable-img", "Matched item is c-evictable-img")
        runner.assertEqual(candidates.first?.bytes, Int64(2 * 1024 * 1024), "Candidate freed bytes is 2MB")
    }

    private static func testClipStorageQueries(runner: TestRunner.Type) {
        runner.assertTrue(ClipStorageQueries.byteSizeExpr.contains("media_size"), "byteSizeExpr should prefer media_size")
        runner.assertTrue(ClipStorageQueries.timestampSecondsExpr.contains("10000000000"), "timestampSecondsExpr should normalize millisecond timestamps")

        guard let db = try? MemoryDatabaseHelper.createInMemoryDatabase() else {
            runner.assertTrue(false, "Failed to create in-memory database for ClipStorageQueries test")
            return
        }

        let nowSec: Int64 = 1_700_000_000
        let oldMsTimestamp = (nowSec - 200 * 86_400) * 1000
        let recentSecTimestamp = nowSec - 5 * 86_400
        let largeRichTextBlob = Blob(bytes: [UInt8](repeating: 0x41, count: 1_200_000))
        let smallImageBlob = Blob(bytes: [0x89, 0x50, 0x4E, 0x47])

        do {
            try db.run(
                """
                INSERT INTO Clip (unique_id, type, data, timestamp, app_id, search_text, length, "group", hidden, media_size)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
                "uid-old-unstarred-img", "public.png", smallImageBlob, oldMsTimestamp, "com.apple.Preview", "", 0, -1, 0, Int64(6 * 1024 * 1024)
            )
            try db.run(
                """
                INSERT INTO Clip (unique_id, type, data, timestamp, app_id, search_text, length, "group", hidden, media_size)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
                "uid-old-starred-img", "public.png", smallImageBlob, nowSec - 200 * 86_400, "com.apple.Preview", "", 0, 1, 0, Int64(6 * 1024 * 1024)
            )
            try db.run(
                """
                INSERT INTO Clip (unique_id, type, data, timestamp, app_id, search_text, length, "group", hidden, media_size)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
                "uid-recent-small-img", "public.png", smallImageBlob, recentSecTimestamp, "com.apple.Preview", "", 0, -1, 0, Int64(0)
            )
            try db.run(
                """
                INSERT INTO Clip (unique_id, type, data, timestamp, app_id, search_text, length, "group", hidden, media_size)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
                "uid-large-richtext", "public.rtf", largeRichTextBlob, recentSecTimestamp, "com.apple.TextEdit", "rich", 10, -1, 0, Int64(0)
            )

            // 验证类型占比 SQL 可执行并正确聚合数量与字节
            var typeCounts: [String: Int64] = [:]
            for row in try db.prepare(ClipStorageQueries.typeProportionsSQL) {
                if let type = row[0] as? String, let count = row[1] as? Int64 {
                    typeCounts[type] = count
                }
            }
            runner.assertEqual(typeCounts["public.png"], 3, "typeProportionsSQL should count 3 image items")
            runner.assertEqual(typeCounts["public.rtf"], 1, "typeProportionsSQL should count 1 richText item")

            // 验证全部 6 种预设过滤条件均可构造可执行 SQL 且过滤语义正确
            for filter in StoragePresetFilter.allCases {
                let whereClause = ClipStorageQueries.topStorageItemsWhereClause(for: filter, nowSec: nowSec)
                let sql = ClipStorageQueries.topStorageItemsSQL(whereClause: whereClause, limit: 20)
                let stmt = try db.prepare(sql)
                let uidCol = stmt.columnNames.firstIndex(of: "unique_id")
                runner.assertTrue(uidCol != nil, "topStorageItemsSQL should select unique_id for \(filter.rawValue)")
                var uids = Set<String>()
                if let uidCol {
                    for row in stmt {
                        if let uid = row[uidCol] as? String {
                            uids.insert(uid)
                        }
                    }
                }
                switch filter {
                case .all:
                    runner.assertEqual(uids.count, 4, ".all filter should return all 4 items")
                case .oneMonthUnstarredImages, .threeMonthsUnstarredImages, .sixMonthsUnstarredImages:
                    runner.assertEqual(uids, ["uid-old-unstarred-img"], "\(filter.rawValue) should match only old unstarred image")
                case .largeImages:
                    runner.assertEqual(uids, ["uid-old-unstarred-img", "uid-old-starred-img"], ".largeImages should match >5MB images")
                case .largeRichText:
                    runner.assertEqual(uids, ["uid-large-richtext"], ".largeRichText should match >1MB richText")
                }
            }

            // 验证冷库淘汰候选查询 SQL 可执行且包含尺寸/时间戳规则
            let cutoffSec = nowSec - 90 * 86_400
            let countSQL = ClipStorageQueries.evictionCandidatesCountSQL(cutoffSec: cutoffSec)
            let itemsSQL = ClipStorageQueries.evictionItemsSQL(selectIdColumn: "unique_id", cutoffSec: cutoffSec)
            runner.assertTrue(countSQL.contains("media_size"), "evictionCandidatesCountSQL should inspect media_size")
            runner.assertTrue(itemsSQL.contains("10000000000"), "evictionItemsSQL should normalize timestamps")

            var evictCount: Int64 = -1
            for row in try db.prepare(countSQL) {
                evictCount = (row[0] as? Int64) ?? -1
            }
            runner.assertEqual(evictCount, 1, "evictionCandidatesCountSQL should find 1 candidate")

            let evictStmt = try db.prepare(itemsSQL)
            let evictUidCol = evictStmt.columnNames.firstIndex(of: "unique_id")
            runner.assertTrue(evictUidCol != nil, "evictionItemsSQL should select unique_id")
            var evictUids: [String] = []
            if let evictUidCol {
                for row in evictStmt {
                    if let uid = row[evictUidCol] as? String {
                        evictUids.append(uid)
                    }
                }
            }
            runner.assertEqual(evictUids, ["uid-old-unstarred-img"], "evictionItemsSQL should target old unstarred ungrouped image")
        } catch {
            runner.assertTrue(false, "ClipStorageQueries execution failed: \(error)")
        }
    }
}
