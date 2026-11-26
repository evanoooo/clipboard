//
//  QuickClearTests.swift
//  Tests
//
//  Unit tests for QuickClearRange and tagged/pinned exclusion predicates.
//

import AppKit
import Carbon
import Foundation
import SQLite

@MainActor
enum QuickClearTests {
    static func run(runner: TestRunner.Type) {
        print("\n--- Testing Quick Clear Predicates ---")

        testShortcutMatching(runner: runner)

        let fixedDate = Date(timeIntervalSince1970: 1_700_000_000)
        runner.assertEqual(
            QuickClearRange.oneHour.cutoff(now: fixedDate),
            1_700_000_000 - 3600,
            "oneHour cutoff should subtract 3600 seconds"
        )
        runner.assertEqual(
            QuickClearRange.thirtyMinutes.cutoff(now: fixedDate),
            1_700_000_000 - 1800,
            "thirtyMinutes cutoff should subtract 1800 seconds"
        )
        runner.assertEqual(
            QuickClearRange.threeHours.cutoff(now: fixedDate),
            1_700_000_000 - 10800,
            "threeHours cutoff should subtract 10800 seconds"
        )
        runner.assertEqual(
            QuickClearRange.oneDay.cutoff(now: fixedDate),
            1_700_000_000 - 86400,
            "oneDay cutoff should subtract 86400 seconds"
        )

        do {
            let db = try MemoryDatabaseHelper.createInMemoryDatabase()
            let table = MemoryDatabaseHelper.clipTable
            let nowTs: Int64 = 1_700_000_000
            let cutoff = QuickClearRange.thirtyMinutes.cutoff(now: Date(timeIntervalSince1970: TimeInterval(nowTs)))

            func insertItem(uid: String, timestamp: Int64, group: Int, hidden: Int = 0) throws {
                let data = uid.data(using: .utf8)!
                try db.run(
                    table.insert(
                        Col.uniqueId <- uid,
                        Col.type <- "public.utf8-plain-text",
                        Col.data <- data,
                        Col.showData <- data,
                        Col.timestamp <- timestamp,
                        Col.appID <- 1,
                        Col.searchText <- uid,
                        Col.length <- uid.count,
                        Col.group <- group,
                        Col.hidden <- hidden
                    )
                )
            }

            // 1. 普通近期记录 -> 应删除
            try insertItem(uid: "normal-recent", timestamp: nowTs - 60, group: -1, hidden: 0)
            // 2. 普通更早记录 -> 应保留
            try insertItem(uid: "normal-old", timestamp: cutoff - 1, group: -1, hidden: 0)
            // 3. 带标签近期记录 -> 应保留
            try insertItem(uid: "tagged-recent", timestamp: nowTs - 30, group: 2, hidden: 0)
            // 4. 带标签且隐藏近期记录 -> 应保留
            try insertItem(uid: "tagged-hidden-recent", timestamp: nowTs - 10, group: 2, hidden: 1)

            let clearableCount = try db.scalar(table.filter(QuickClearRange.clearable(since: cutoff)).count)
            let skippedCount = try db.scalar(table.filter(QuickClearRange.skipped(since: cutoff)).count)
            runner.assertEqual(clearableCount, 1, "Only ungrouped recent record should be clearable")
            runner.assertEqual(skippedCount, 2, "Tagged/pinned recent records should be counted as skipped")

            let deleted = try db.run(table.filter(QuickClearRange.clearable(since: cutoff)).delete())
            runner.assertEqual(deleted, 1, "Should delete exactly 1 clearable record")

            let remainingUids = try db.prepare(table.select(Col.uniqueId)).map { $0[Col.uniqueId] }
            runner.assertEqual(
                Set(remainingUids),
                Set(["normal-old", "tagged-recent", "tagged-hidden-recent"]),
                "Old normal item and all tagged/hidden items must survive quick clear"
            )
            print("✓ Quick Clear tests passed!")
        } catch {
            runner.assertTrue(false, "QuickClearTests failed with error: \(error)")
        }
    }

    private static func matchesQuickClearShortcut(_ event: NSEvent) -> Bool {
        let deleteKey = UInt16(kVK_Delete)
        let forwardDeleteKey = UInt16(kVK_ForwardDelete)
        guard event.keyCode == deleteKey || event.keyCode == forwardDeleteKey else {
            return false
        }
        let relevant: NSEvent.ModifierFlags = [.command, .option, .control, .shift]
        return event.modifierFlags.intersection(relevant) == [.command, .shift]
    }

    private static func makeKeyEvent(
        keyCode: UInt16,
        modifiers: NSEvent.ModifierFlags
    ) -> NSEvent? {
        NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: modifiers,
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: "",
            charactersIgnoringModifiers: "",
            isARepeat: false,
            keyCode: keyCode
        )
    }

    private static func testShortcutMatching(runner: TestRunner.Type) {
        let cmdShiftDelete = makeKeyEvent(keyCode: UInt16(kVK_Delete), modifiers: [.command, .shift])!
        let cmdShiftForwardDelete = makeKeyEvent(keyCode: UInt16(kVK_ForwardDelete), modifiers: [.command, .shift])!
        let cmdDelete = makeKeyEvent(keyCode: UInt16(kVK_Delete), modifiers: [.command])!
        let cmdOptShiftDelete = makeKeyEvent(keyCode: UInt16(kVK_Delete), modifiers: [.command, .option, .shift])!
        let cmdShiftC = makeKeyEvent(keyCode: UInt16(kVK_ANSI_C), modifiers: [.command, .shift])!

        runner.assertTrue(matchesQuickClearShortcut(cmdShiftDelete), "⌘⇧Delete should match quick clear shortcut")
        runner.assertTrue(matchesQuickClearShortcut(cmdShiftForwardDelete), "⌘⇧ForwardDelete should match quick clear shortcut")
        runner.assertFalse(matchesQuickClearShortcut(cmdDelete), "⌘Delete alone must not match quick clear shortcut")
        runner.assertFalse(matchesQuickClearShortcut(cmdOptShiftDelete), "⌘⌥⇧Delete must not match quick clear shortcut")
        runner.assertFalse(matchesQuickClearShortcut(cmdShiftC), "⌘⇧C must not match quick clear shortcut")
    }
}
