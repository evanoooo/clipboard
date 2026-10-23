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
            group: -1
        )
        let entry2 = SyncIndexEntry(
            uniqueId: "uuid-clip-002",
            updatedAt: 1729650002000,
            checksum: "81706f5e4d3c2b1a",
            isDeleted: true,
            group: 42
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

        print("✓ Sync Models & Index Serialization tests passed!")
    }
}
