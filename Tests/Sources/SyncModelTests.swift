//
//  SyncModelTests.swift
//  Tests
//
//  Unit tests for WebDAV Sync Models, Index Serialization & SyncItemBlob Serialization.
//

import Foundation

@MainActor
enum SyncModelTests {
    static func run(runner: TestRunner.Type) {
        print("\n--- Testing Sync Models & Index Serialization ---")

        // 1. SyncIndex Encoding & Decoding
        var index = SyncIndex(version: 1, lastModified: 1729650000000)
        let entry1 = SyncIndexEntry(
            uniqueId: "uuid-clip-001",
            updatedAt: 1729650001000,
            checksum: "a1b2c3d4e5f60718",
            isDeleted: false,
            group: -1,
            type: "public.utf8-plain-text",
            tag: "",
            size: 120
        )
        let entry2 = SyncIndexEntry(
            uniqueId: "uuid-clip-002",
            updatedAt: 1729650002000,
            checksum: "81706f5e4d3c2b1a",
            isDeleted: true,
            group: 42,
            type: "public.png",
            tag: "deleted",
            size: 500
        )
        index.entries["uuid-clip-001"] = entry1
        index.entries["uuid-clip-002"] = entry2

        do {
            let encodedData = try JSONEncoder().encode(index)
            let decodedIndex = try JSONDecoder().decode(SyncIndex.self, from: encodedData)

            runner.assertEqual(decodedIndex.version, 1, "Index version mismatch")
            runner.assertEqual(decodedIndex.lastModified, 1729650000000, "Index lastModified mismatch")
            runner.assertEqual(decodedIndex.entries.count, 2, "Decoded entries count mismatch")

            let fetchedEntry1 = decodedIndex.entries["uuid-clip-001"]
            runner.assertTrue(fetchedEntry1 != nil, "Entry 1 must exist")
            runner.assertEqual(fetchedEntry1?.uniqueId, "uuid-clip-001", "uniqueId mismatch")
            runner.assertEqual(fetchedEntry1?.checksum, "a1b2c3d4e5f60718", "checksum mismatch")
            runner.assertEqual(fetchedEntry1?.isDeleted, false, "isDeleted mismatch")
            runner.assertEqual(fetchedEntry1?.group, -1, "group mismatch")
            runner.assertEqual(fetchedEntry1?.type, "public.utf8-plain-text", "type mismatch")
            runner.assertEqual(fetchedEntry1?.size, 120, "size mismatch")

            let fetchedEntry2 = decodedIndex.entries["uuid-clip-002"]
            runner.assertTrue(fetchedEntry2 != nil, "Entry 2 must exist")
            runner.assertEqual(fetchedEntry2?.isDeleted, true, "Entry 2 must be tombstone")
            runner.assertEqual(fetchedEntry2?.group, 42, "Entry 2 group mismatch")
        } catch {
            runner.assertTrue(false, "Index JSON encode/decode failed: \(error)")
        }

        // 2. SyncItemBlob Serialization Round-trip
        let textData = "let greeting = \"Hello Sync!\"".data(using: .utf8)!
        let sourceBlob = SyncItemBlob(
            uniqueId: "unique-xcode-clip-100",
            pasteboardType: "public.utf8-plain-text",
            payloadData: textData,
            showData: textData,
            timestamp: 1729653330000,
            group: 5,
            tag: "swift_code",
            alias: "swift_greeting",
            sourceAppName: "Xcode"
        )

        runner.assertEqual(sourceBlob.uniqueId, "unique-xcode-clip-100", "Blob uniqueId mismatch")
        runner.assertEqual(sourceBlob.pasteboardType, "public.utf8-plain-text", "Blob type mismatch")
        runner.assertEqual(sourceBlob.group, 5, "Blob group mismatch")
        runner.assertEqual(sourceBlob.alias, "swift_greeting", "Blob alias mismatch")
        runner.assertEqual(sourceBlob.tag, "swift_code", "Blob tag mismatch")
        runner.assertEqual(sourceBlob.sourceAppName, "Xcode", "Blob appName mismatch")

        do {
            let blobData = try JSONEncoder().encode(sourceBlob)
            let decodedBlob = try JSONDecoder().decode(SyncItemBlob.self, from: blobData)

            runner.assertEqual(decodedBlob.uniqueId, sourceBlob.uniqueId, "Restored uniqueId mismatch")
            runner.assertEqual(decodedBlob.pasteboardType, sourceBlob.pasteboardType, "Restored type mismatch")
            runner.assertEqual(decodedBlob.group, sourceBlob.group, "Restored group mismatch")
            runner.assertEqual(decodedBlob.alias, sourceBlob.alias, "Restored alias mismatch")
            runner.assertEqual(decodedBlob.tag, sourceBlob.tag, "Restored tag mismatch")
            runner.assertEqual(decodedBlob.payloadData, textData, "Restored binary data mismatch")
            runner.assertEqual(decodedBlob.sourceAppName, "Xcode", "Restored appName mismatch")
        } catch {
            runner.assertTrue(false, "SyncItemBlob JSON roundtrip failed: \(error)")
        }

        // 3. SyncSummary Generation & Breakdown
        var summaryIndex = SyncIndex(version: 1, lastModified: 1729655555000)
        // 3 active normal items
        summaryIndex.entries["item-norm-1"] = SyncIndexEntry(uniqueId: "item-norm-1", updatedAt: 100, checksum: "c1", isDeleted: false, group: -1, type: "public.utf8-plain-text", tag: "", size: 50)
        summaryIndex.entries["item-norm-2"] = SyncIndexEntry(uniqueId: "item-norm-2", updatedAt: 101, checksum: "c2", isDeleted: false, group: -1, type: "public.utf8-plain-text", tag: "", size: 60)
        summaryIndex.entries["item-norm-3"] = SyncIndexEntry(uniqueId: "item-norm-3", updatedAt: 102, checksum: "c3", isDeleted: false, group: -1, type: "public.rtf", tag: "", size: 100)

        // 2 pinned items in Group 1 ("常用收藏")
        summaryIndex.entries["item-pinned-1"] = SyncIndexEntry(uniqueId: "item-pinned-1", updatedAt: 103, checksum: "c4", isDeleted: false, group: 1, type: "public.png", tag: "", size: 500)
        summaryIndex.entries["item-pinned-2"] = SyncIndexEntry(uniqueId: "item-pinned-2", updatedAt: 104, checksum: "c5", isDeleted: false, group: 1, type: "public.tiff", tag: "", size: 600)

        // 1 item in Group 2 ("代码片段")
        summaryIndex.entries["item-code-1"] = SyncIndexEntry(uniqueId: "item-code-1", updatedAt: 105, checksum: "c6", isDeleted: false, group: 2, type: "public.utf8-plain-text", tag: "", size: 80)

        // 1 tombstone (must not be counted)
        summaryIndex.entries["item-deleted-1"] = SyncIndexEntry(uniqueId: "item-deleted-1", updatedAt: 106, checksum: "c7", isDeleted: true, group: 1, type: "public.utf8-plain-text", tag: "", size: 200)

        let chips: [CategoryChip] = [
            CategoryChip(id: -1, name: "剪贴板", colorIndex: 0, isSystem: true),
            CategoryChip(id: 1, name: "常用收藏", colorIndex: 1, isSystem: false, customHexColor: "#007AFF"),
            CategoryChip(id: 2, name: "代码片段", colorIndex: 2, isSystem: false, customHexColor: "#34C759")
        ]

        let summary = summaryIndex.generateSummary(chips: chips)

        runner.assertEqual(summary.totalCount, 6, "Total active count must be 6 (tombstone excluded)")
        runner.assertEqual(summary.lastUpdated, 1729655555000, "lastUpdated mismatch")
        runner.assertTrue(summary.totalBytes > 0, "Total bytes must be > 0")
        runner.assertTrue(!summary.formattedStorageSize.isEmpty, "formattedStorageSize must not be empty")

        // Group counts
        runner.assertEqual(summary.groupCounts.count, 3, "Must have 3 groups")
        let normalGroup = summary.groupCounts.first(where: { $0.groupId == -1 })
        runner.assertTrue(normalGroup != nil, "Default clipboard group must exist")
        runner.assertEqual(normalGroup?.count, 3, "Default clipboard group count must be 3")

        let favGroup = summary.groupCounts.first(where: { $0.groupId == 1 })
        runner.assertTrue(favGroup != nil, "Group 1 must exist")
        runner.assertEqual(favGroup?.count, 2, "Group 1 count must be 2")
        runner.assertEqual(favGroup?.name, "常用收藏", "Group 1 name mismatch")
        runner.assertEqual(favGroup?.colorHex, "#007AFF", "Group 1 color mismatch")

        let codeGroup = summary.groupCounts.first(where: { $0.groupId == 2 })
        runner.assertTrue(codeGroup != nil, "Group 2 must exist")
        runner.assertEqual(codeGroup?.count, 1, "Group 2 count must be 1")

        // Type counts: 3 plain text + 1 code (text) = 4 text; 2 images = 2; 1 rtf = 1
        let imageType = summary.typeCounts.first(where: { $0.typeName == "图片" })
        runner.assertTrue(imageType != nil, "Images type must exist")
        runner.assertEqual(imageType?.count, 2, "Images count must be 2")

        let textType = summary.typeCounts.first(where: { $0.typeName == "文本" })
        runner.assertTrue(textType != nil, "Text type must exist")
        runner.assertEqual(textType?.count, 3, "Text count must be 3")

        // Encode and decode summary
        do {
            let summaryData = try JSONEncoder().encode(summary)
            let decodedSummary = try JSONDecoder().decode(SyncSummary.self, from: summaryData)
            runner.assertEqual(decodedSummary.totalCount, 6, "Decoded summary count mismatch")
            runner.assertEqual(decodedSummary.groupCounts.count, 3, "Decoded group count mismatch")
            runner.assertTrue(decodedSummary.totalBytes > 0, "Decoded total bytes must be > 0")
        } catch {
            runner.assertTrue(false, "SyncSummary encode/decode failed: \(error)")
        }

        // Sharded & Legacy Path Resolution
        let sha256Id = "0007e2a89e9e2d596ffeeb13823dc7d24dfb94070b98c7c5b0dfceba03bb1828"
        runner.assertEqual(
            SyncIndex.shardedItemPath(for: sha256Id),
            "ClipboardSync/items/00/0007e2a89e9e2d596ffeeb13823dc7d24dfb94070b98c7c5b0dfceba03bb1828.enc",
            "Sharded path should use first 2 chars as folder"
        )
        runner.assertEqual(
            SyncIndex.legacyItemPath(for: sha256Id),
            "ClipboardSync/items/0007e2a89e9e2d596ffeeb13823dc7d24dfb94070b98c7c5b0dfceba03bb1828.enc",
            "Legacy path should remain flat"
        )
        let shortId = "a"
        runner.assertEqual(
            SyncIndex.shardedItemPath(for: shortId),
            "ClipboardSync/items/misc/a.enc",
            "Short ID should fallback to misc folder"
        )

        // Test Tombstone Pruning (30-day retention)
        var pruneIndex = SyncIndex()
        let nowMillis: Int64 = 1_000_000_000_000
        let dayMillis: Int64 = 24 * 3600 * 1000

        // 1. Alive item (should NEVER be pruned, even if old)
        pruneIndex.entries["alive-old"] = SyncIndexEntry(uniqueId: "alive-old", updatedAt: nowMillis - 40 * dayMillis, checksum: "c1", isDeleted: false)

        // 2. Tombstone within 30 days (should NOT be pruned yet)
        pruneIndex.entries["tombstone-recent"] = SyncIndexEntry(uniqueId: "tombstone-recent", updatedAt: nowMillis - 10 * dayMillis, checksum: "", isDeleted: true)

        // 3. Tombstone older than 30 days (MUST be pruned)
        pruneIndex.entries["tombstone-expired"] = SyncIndexEntry(uniqueId: "tombstone-expired", updatedAt: nowMillis - 31 * dayMillis, checksum: "", isDeleted: true)

        // 4. Tombstone exactly 35 days old (MUST be pruned)
        pruneIndex.entries["tombstone-expired-2"] = SyncIndexEntry(uniqueId: "tombstone-expired-2", updatedAt: nowMillis - 35 * dayMillis, checksum: "", isDeleted: true)

        let prunedCount = pruneIndex.pruneExpiredTombstones(retentionDays: 30, currentTimeMillis: nowMillis)
        runner.assertEqual(prunedCount, 2, "Exactly 2 expired tombstones must be pruned")
        runner.assertEqual(pruneIndex.entries.count, 2, "2 items should remain")
        runner.assertTrue(pruneIndex.entries["alive-old"] != nil, "Alive item must be kept")
        runner.assertTrue(pruneIndex.entries["tombstone-recent"] != nil, "Recent tombstone must be kept")
        runner.assertTrue(pruneIndex.entries["tombstone-expired"] == nil, "Expired tombstone must be removed")
        runner.assertTrue(pruneIndex.entries["tombstone-expired-2"] == nil, "Expired tombstone 2 must be removed")

        print("✓ Sync Models, Summary & Index Serialization tests passed!")
    }
}
