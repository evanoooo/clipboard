//
//  QuickPasteShortcutTests.swift
//  Tests
//
//  Unit tests for Quick Paste Command+1~9 shortcut matching and digit index mapping.
//

import AppKit
import Carbon
import Foundation

@MainActor
enum QuickPasteShortcutTests {
    static func run(runner: TestRunner.Type) {
        print("\n--- Testing Quick Paste Shortcut Matching & ⌘1~9 Resolution ---")
        testDigitIndexMapping(runner: runner)
        testCommand1to9KeyEvents(runner: runner)
        testConflictModifierRejection(runner: runner)
        testPlainTextModifierAllowance(runner: runner)
        testCommandFSearchShortcut(runner: runner)
        print("✓ Quick Paste Shortcut tests passed!")
    }

    private static func digitIndex(for keyCode: UInt16) -> Int? {
        let one: UInt16 = .init(kVK_ANSI_1)
        let two: UInt16 = .init(kVK_ANSI_2)
        let three: UInt16 = .init(kVK_ANSI_3)
        let four: UInt16 = .init(kVK_ANSI_4)
        let five: UInt16 = .init(kVK_ANSI_5)
        let six: UInt16 = .init(kVK_ANSI_6)
        let seven: UInt16 = .init(kVK_ANSI_7)
        let eight: UInt16 = .init(kVK_ANSI_8)
        let nine: UInt16 = .init(kVK_ANSI_9)

        let keypad1: UInt16 = .init(kVK_ANSI_Keypad1)
        let keypad2: UInt16 = .init(kVK_ANSI_Keypad2)
        let keypad3: UInt16 = .init(kVK_ANSI_Keypad3)
        let keypad4: UInt16 = .init(kVK_ANSI_Keypad4)
        let keypad5: UInt16 = .init(kVK_ANSI_Keypad5)
        let keypad6: UInt16 = .init(kVK_ANSI_Keypad6)
        let keypad7: UInt16 = .init(kVK_ANSI_Keypad7)
        let keypad8: UInt16 = .init(kVK_ANSI_Keypad8)
        let keypad9: UInt16 = .init(kVK_ANSI_Keypad9)

        switch keyCode {
        case one, keypad1: return 0
        case two, keypad2: return 1
        case three, keypad3: return 2
        case four, keypad4: return 3
        case five, keypad5: return 4
        case six, keypad6: return 5
        case seven, keypad7: return 6
        case eight, keypad8: return 7
        case nine, keypad9: return 8
        default: return nil
        }
    }

    private static func matchQuickPaste(
        event: NSEvent,
        modifierIndex: Int = 0,
        plainTextModifierIndex: Int = 3
    ) -> Int? {
        let modifierFlags: (Int) -> NSEvent.ModifierFlags = { index in
            switch index {
            case 0: return .command
            case 1: return .option
            case 2: return .control
            case 3: return .shift
            default: return .command
            }
        }

        let required = modifierFlags(modifierIndex)
        guard event.modifierFlags.contains(required) else { return nil }

        let plain = modifierFlags(plainTextModifierIndex)
        let allowed: NSEvent.ModifierFlags = [required, plain]

        let others = event.modifierFlags
            .intersection([.command, .option, .control, .shift])
            .subtracting(allowed)

        guard others.isEmpty else { return nil }

        return digitIndex(for: event.keyCode)
    }

    private static func makeKeyEvent(keyCode: UInt16, modifiers: NSEvent.ModifierFlags, chars: String = "") -> NSEvent {
        NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: modifiers,
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: chars,
            charactersIgnoringModifiers: chars,
            isARepeat: false,
            keyCode: keyCode
        )!
    }

    private static func testDigitIndexMapping(runner: TestRunner.Type) {
        runner.assertEqual(digitIndex(for: UInt16(kVK_ANSI_1)), 0, "1 should map to index 0")
        runner.assertEqual(digitIndex(for: UInt16(kVK_ANSI_2)), 1, "2 should map to index 1")
        runner.assertEqual(digitIndex(for: UInt16(kVK_ANSI_9)), 8, "9 should map to index 8")
        runner.assertEqual(digitIndex(for: UInt16(kVK_ANSI_Keypad5)), 4, "Keypad 5 should map to index 4")
        runner.assertEqual(digitIndex(for: UInt16(kVK_ANSI_0)), nil, "0 should not map to any index")
        runner.assertEqual(digitIndex(for: UInt16(kVK_ANSI_A)), nil, "A should not map to any index")
    }

    private static func testCommand1to9KeyEvents(runner: TestRunner.Type) {
        let ansiKeys: [UInt16] = [
            UInt16(kVK_ANSI_1), UInt16(kVK_ANSI_2), UInt16(kVK_ANSI_3),
            UInt16(kVK_ANSI_4), UInt16(kVK_ANSI_5), UInt16(kVK_ANSI_6),
            UInt16(kVK_ANSI_7), UInt16(kVK_ANSI_8), UInt16(kVK_ANSI_9)
        ]

        for (expectedIndex, keyCode) in ansiKeys.enumerated() {
            let event = makeKeyEvent(keyCode: keyCode, modifiers: [.command], chars: "\(expectedIndex + 1)")
            let matched = matchQuickPaste(event: event)
            runner.assertEqual(matched, expectedIndex, "⌘+\(expectedIndex + 1) should match index \(expectedIndex)")
        }
    }

    private static func testConflictModifierRejection(runner: TestRunner.Type) {
        // ⌘ + ⌥ + 1 不应当触发快捷粘贴
        let event = makeKeyEvent(keyCode: UInt16(kVK_ANSI_1), modifiers: [.command, .option], chars: "1")
        runner.assertEqual(matchQuickPaste(event: event), nil, "⌘+⌥+1 should be rejected")

        // ⌘ + ⌃ + 2 不应当触发快捷粘贴
        let event2 = makeKeyEvent(keyCode: UInt16(kVK_ANSI_2), modifiers: [.command, .control], chars: "2")
        runner.assertEqual(matchQuickPaste(event: event2), nil, "⌘+⌃+2 should be rejected")
    }

    private static func testPlainTextModifierAllowance(runner: TestRunner.Type) {
        // ⌘ + ⇧ + 1 附带了纯文本修饰键（Shift），应当被正常识别并映射为 index 0
        let event = makeKeyEvent(keyCode: UInt16(kVK_ANSI_1), modifiers: [.command, .shift], chars: "1")
        runner.assertEqual(matchQuickPaste(event: event), 0, "⌘+⇧+1 with plain-text modifier should match index 0")
    }

    private static func testCommandFSearchShortcut(runner: TestRunner.Type) {
        let fKeyCode = UInt16(kVK_ANSI_F)
        // ⌘ + F 应当准确匹配搜索快捷键规则（仅 Command，不带 Option/Control/Shift）
        let validCommandF = makeKeyEvent(keyCode: fKeyCode, modifiers: [.command], chars: "f")
        let isCommandF = validCommandF.keyCode == fKeyCode &&
            validCommandF.modifierFlags.contains(.command) &&
            validCommandF.modifierFlags.isDisjoint(with: [.option, .control, .shift])
        runner.assertTrue(isCommandF, "⌘+F without conflicting modifiers must be recognized as search trigger")

        // ⌘ + ⌥ + F 或 ⌘ + ⇧ + F 不应误触发普通搜索框聚焦
        let conflictEvent = makeKeyEvent(keyCode: fKeyCode, modifiers: [.command, .option], chars: "f")
        let isConflict = conflictEvent.modifierFlags.isDisjoint(with: [.option, .control, .shift])
        runner.assertFalse(isConflict, "⌘+⌥+F must not be treated as standard ⌘+F search trigger")
    }
}
