//
//  SyncDiffTests.swift
//  Tests
//
//  Unit tests for WebDAV Sync Diff calculation, LWW conflict resolution & Tombstone handling.
//

import Foundation

@MainActor
enum SyncDiffTests {
    static func run(runner: TestRunner.Type) {
        print("\n--- Testing SyncEngine Diff Calculation & LWW ---")

        let data1 = "Hello 1".data(using: .utf8)!
        let data2 = "Hello 2".data(using: .utf8)!
        let checksum1 = SyncCryptoEngine.checksum(for: data1)
        let checksum2 = SyncCryptoEngine.checksum(for: data2)

        // 1. Local-only item -> ToUpload
        let localItem1 = SyncItemBlob(uniqueId: "id-001", pasteboardType: "text", payloadData: data1, timestamp: 1000, group: -1)
        let remoteIndexEmpty = SyncIndex()
        let diff1 = SyncDiffEngine.calculateDiff(localItems: [localItem1], remoteIndex: remoteIndexEmpty, onlySyncPinned: false)
        runner.assertEqual(diff1.toUpload.count, 1, "Local-only item must be queued for upload")
        runner.assertEqual(diff1.toDownload.count, 0, "No downloads expected")
        runner.assertEqual(diff1.toUpload.first?.uniqueId, "id-001", "Upload item ID mismatch")

        // 2. Remote-only item -> ToDownload
        var remoteIndex2 = SyncIndex()
        remoteIndex2.entries["id-002"] = SyncIndexEntry(uniqueId: "id-002", updatedAt: 2000, checksum: checksum1, isDeleted: false, group: -1)
        let diff2 = SyncDiffEngine.calculateDiff(localItems: [], remoteIndex: remoteIndex2, onlySyncPinned: false)
        runner.assertEqual(diff2.toDownload.count, 1, "Remote-only item must be queued for download")
        runner.assertEqual(diff2.toDownload.first, "id-002", "Download item ID mismatch")
        runner.assertEqual(diff2.toUpload.count, 0, "No uploads expected")

        // 3. Remote newer with different checksum -> ToDownload
        let localOld = SyncItemBlob(uniqueId: "id-003", pasteboardType: "text", payloadData: data1, timestamp: 1000, group: -1)
        var remoteIndex3 = SyncIndex()
        remoteIndex3.entries["id-003"] = SyncIndexEntry(uniqueId: "id-003", updatedAt: 2000, checksum: checksum2, isDeleted: false, group: -1)
        let diff3 = SyncDiffEngine.calculateDiff(localItems: [localOld], remoteIndex: remoteIndex3, onlySyncPinned: false)
        runner.assertEqual(diff3.toDownload.count, 1, "Remote newer must trigger download")
        runner.assertEqual(diff3.toDownload.first, "id-003", "ID mismatch")
        runner.assertEqual(diff3.toUpload.count, 0, "Should not upload old version")

        // 4. Local newer with different checksum -> ToUpload
        let localNewer = SyncItemBlob(uniqueId: "id-004", pasteboardType: "text", payloadData: data2, timestamp: 3000, group: -1)
        var remoteIndex4 = SyncIndex()
        remoteIndex4.entries["id-004"] = SyncIndexEntry(uniqueId: "id-004", updatedAt: 1000, checksum: checksum1, isDeleted: false, group: -1)
        let diff4 = SyncDiffEngine.calculateDiff(localItems: [localNewer], remoteIndex: remoteIndex4, onlySyncPinned: false)
        runner.assertEqual(diff4.toUpload.count, 1, "Local newer must trigger upload")
        runner.assertEqual(diff4.toUpload.first?.uniqueId, "id-004", "ID mismatch")
        runner.assertEqual(diff4.toDownload.count, 0, "No downloads expected")

        // 5. Identical data -> No actions (0 transfer)
        let localSame = SyncItemBlob(uniqueId: "id-005", pasteboardType: "text", payloadData: data1, timestamp: 1000, group: -1)
        var remoteIndex5 = SyncIndex()
        remoteIndex5.entries["id-005"] = SyncIndexEntry(uniqueId: "id-005", updatedAt: 1000, checksum: checksum1, isDeleted: false, group: -1)
        let diff5 = SyncDiffEngine.calculateDiff(localItems: [localSame], remoteIndex: remoteIndex5, onlySyncPinned: false)
        runner.assertEqual(diff5.toUpload.count, 0, "Identical item should not upload")
        runner.assertEqual(diff5.toDownload.count, 0, "Identical item should not download")

        // 6. Remote Tombstone -> ToDeleteLocal
        let localAlive = SyncItemBlob(uniqueId: "id-006", pasteboardType: "text", payloadData: data1, timestamp: 1000, group: -1)
        var remoteIndex6 = SyncIndex()
        remoteIndex6.entries["id-006"] = SyncIndexEntry(uniqueId: "id-006", updatedAt: 2000, checksum: "", isDeleted: true, group: -1)
        let diff6 = SyncDiffEngine.calculateDiff(localItems: [localAlive], remoteIndex: remoteIndex6, onlySyncPinned: false)
        runner.assertEqual(diff6.toDeleteLocal.count, 1, "Remote tombstone must trigger local delete")
        runner.assertEqual(diff6.toDeleteLocal.first, "id-006", "Delete ID mismatch")

        // 6.1 Local newer than Remote Tombstone -> ToUpload (LWW Resurrection)
        let localResurrected = SyncItemBlob(uniqueId: "id-006-resurrect", pasteboardType: "text", payloadData: data1, timestamp: 3000, group: -1)
        var remoteIndex61 = SyncIndex()
        remoteIndex61.entries["id-006-resurrect"] = SyncIndexEntry(uniqueId: "id-006-resurrect", updatedAt: 2000, checksum: "", isDeleted: true, group: -1)
        let diff61 = SyncDiffEngine.calculateDiff(localItems: [localResurrected], remoteIndex: remoteIndex61, onlySyncPinned: false)
        runner.assertEqual(diff61.toDeleteLocal.count, 0, "Newer local item must NOT be deleted by older tombstone")
        runner.assertEqual(diff61.toUpload.count, 1, "Newer local item must be queued for upload to resurrect")
        runner.assertEqual(diff61.toUpload.first?.uniqueId, "id-006-resurrect", "Resurrect item ID mismatch")

        // 7. OnlySyncPinned filter mode
        let normalItem = SyncItemBlob(uniqueId: "id-normal", pasteboardType: "text", payloadData: data1, timestamp: 1000, group: -1)
        let pinnedItem = SyncItemBlob(uniqueId: "id-pinned", pasteboardType: "text", payloadData: data1, timestamp: 1000, group: 2)
        var remoteIndex7 = SyncIndex()
        remoteIndex7.entries["id-normal-remote"] = SyncIndexEntry(uniqueId: "id-normal-remote", updatedAt: 1000, checksum: checksum1, isDeleted: false, group: -1)
        remoteIndex7.entries["id-pinned-remote"] = SyncIndexEntry(uniqueId: "id-pinned-remote", updatedAt: 1000, checksum: checksum1, isDeleted: false, group: 3)

        let diff7 = SyncDiffEngine.calculateDiff(
            localItems: [normalItem, pinnedItem],
            remoteIndex: remoteIndex7,
            onlySyncPinned: true
        )
        // Should only upload pinnedItem, ignoring normalItem
        runner.assertEqual(diff7.toUpload.count, 1, "Should only upload 1 pinned item")
        runner.assertEqual(diff7.toUpload.first?.uniqueId, "id-pinned", "Only pinned should be uploaded")

        // Should only download id-pinned-remote, ignoring id-normal-remote
        runner.assertEqual(diff7.toDownload.count, 1, "Should only download 1 pinned item")
        runner.assertEqual(diff7.toDownload.first, "id-pinned-remote", "Only pinned should be downloaded")

        print("✓ SyncEngine Diff Calculation & LWW tests passed!")
    }
}
