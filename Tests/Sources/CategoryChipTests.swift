//
//  CategoryChipTests.swift
//  Tests
//
//  Unit tests for CategoryChip custom color functionality, reordering, and JSON backward compatibility.
//

import AppKit
import Foundation

@MainActor
final class CategoryChipTests {
    static func run(runner: TestRunner.Type) {
        print("\n--- Testing CategoryChip & Custom Colors ---")

        testDefaultPresetColor(runner: runner)
        testCustomHexColor(runner: runner)
        testColorPropertySetter(runner: runner)
        testBackwardCompatibleJSONDecoding(runner: runner)
        testFullCodableRoundtrip(runner: runner)
        testNSColorHexConversion(runner: runner)
        testUserChipReordering(runner: runner)

        print("✓ CategoryChip & Custom Colors tests passed!")
    }

    private static func testDefaultPresetColor(runner: TestRunner.Type) {
        let chip = CategoryChip(id: 1, name: "工作", colorIndex: 2, isSystem: false)
        runner.assertEqual(chip.customHexColor, nil, "Default customHexColor should be nil")
        runner.assertEqual(chip.colorIndex, 2, "colorIndex should match")

        // displayNSColor should equal systemGreen
        let expectedColor = CategoryChip.paletteNSColors[2]
        runner.assertEqual(chip.displayNSColor, expectedColor, "displayNSColor should match preset color at index 2")
    }

    private static func testCustomHexColor(runner: TestRunner.Type) {
        let customHex = "#FF3366"
        let chip = CategoryChip(id: 2, name: "设计", colorIndex: 1, isSystem: false, customHexColor: customHex)
        runner.assertEqual(chip.customHexColor, customHex, "customHexColor should be retained")

        let expectedNSColor = NSColor(hex: customHex)
        runner.assertEqual(chip.displayNSColor, expectedNSColor, "displayNSColor should return parsed custom NSColor")
    }

    private static func testColorPropertySetter(runner: TestRunner.Type) {
        var chip = CategoryChip(id: 3, name: "备忘", colorIndex: 0, isSystem: false, customHexColor: "#123456")
        runner.assertEqual(chip.customHexColor, "#123456", "Initial custom color should be set")

        // Updating with a standard palette color should clear customHexColor
        let newPresetColor = CategoryChip.palette[4] // red
        chip.color = newPresetColor

        runner.assertEqual(chip.colorIndex, 4, "colorIndex should be updated to 4")
        runner.assertEqual(chip.customHexColor, nil, "customHexColor should be reset to nil on standard palette update")
    }

    private static func testBackwardCompatibleJSONDecoding(runner: TestRunner.Type) {
        // Legacy JSON without `customHexColor` field
        let legacyJSON = """
        [
            {"id": 1, "name": "默认", "colorIndex": 0, "isSystem": true},
            {"id": 2, "name": "重要", "colorIndex": 4, "isSystem": false}
        ]
        """.data(using: .utf8)!

        do {
            let decoder = JSONDecoder()
            let chips = try decoder.decode([CategoryChip].self, from: legacyJSON)
            runner.assertEqual(chips.count, 2, "Should decode 2 chips from legacy JSON")
            runner.assertEqual(chips[0].name, "默认", "Name matches")
            runner.assertEqual(chips[0].customHexColor, nil, "Missing customHexColor decodes as nil")
            runner.assertEqual(chips[1].colorIndex, 4, "colorIndex matches")
            runner.assertEqual(chips[1].customHexColor, nil, "Missing customHexColor decodes as nil")
        } catch {
            print("❌ Legacy JSON decoding failed: \(error)")
            exit(1)
        }
    }

    private static func testFullCodableRoundtrip(runner: TestRunner.Type) {
        let originalChip = CategoryChip(id: 10, name: "项目", colorIndex: 3, isSystem: false, customHexColor: "#AABBCC")
        
        do {
            let encoder = JSONEncoder()
            let data = try encoder.encode(originalChip)

            let decoder = JSONDecoder()
            let decodedChip = try decoder.decode(CategoryChip.self, from: data)

            runner.assertEqual(decodedChip.id, originalChip.id, "id should match")
            runner.assertEqual(decodedChip.name, originalChip.name, "name should match")
            runner.assertEqual(decodedChip.colorIndex, originalChip.colorIndex, "colorIndex should match")
            runner.assertEqual(decodedChip.isSystem, originalChip.isSystem, "isSystem should match")
            runner.assertEqual(decodedChip.customHexColor, originalChip.customHexColor, "customHexColor should roundtrip")
        } catch {
            print("❌ Full codable roundtrip failed: \(error)")
            exit(1)
        }
    }

    private static func testNSColorHexConversion(runner: TestRunner.Type) {
        let testColor = NSColor(srgbRed: 1.0, green: 0.2, blue: 0.4, alpha: 1.0)
        let hexString = testColor.toHexString(includeAlpha: false)
        runner.assertEqual(hexString, "#FF3366", "Hex string should format RGB accurately")

        let parsedColor = NSColor(hex: "#FF3366")
        let reencodedHex = parsedColor.toHexString(includeAlpha: false)
        runner.assertEqual(reencodedHex, "#FF3366", "Hex roundtrip should match")
    }

    private static func testUserChipReordering(runner: TestRunner.Type) {
        // 模拟 [System, A(1), B(2), C(3)]
        var chips: [CategoryChip] = [
            CategoryChip(id: -1, name: "剪贴板", colorIndex: 0, isSystem: true),
            CategoryChip(id: 1, name: "A", colorIndex: 1, isSystem: false),
            CategoryChip(id: 2, name: "B", colorIndex: 2, isSystem: false),
            CategoryChip(id: 3, name: "C", colorIndex: 3, isSystem: false)
        ]

        func moveChip(fromIndex: Int, toIndex: Int) -> Bool {
            let systemCount = 1
            guard fromIndex >= systemCount, fromIndex < chips.count,
                  toIndex >= systemCount, toIndex < chips.count,
                  fromIndex != toIndex else {
                return false
            }
            let moved = chips.remove(at: fromIndex)
            chips.insert(moved, at: toIndex)
            return true
        }

        // 1. Move A (index 1) to end (index 3) -> [System, B, C, A]
        let res1 = moveChip(fromIndex: 1, toIndex: 3)
        runner.assertTrue(res1, "Moving A to end should succeed")
        runner.assertEqual(chips.map(\.id), [-1, 2, 3, 1], "Order should be System, B, C, A")

        // 2. Move C (index 2) to first user position (index 1) -> [System, C, B, A]
        let res2 = moveChip(fromIndex: 2, toIndex: 1)
        runner.assertTrue(res2, "Moving C forward should succeed")
        runner.assertEqual(chips.map(\.id), [-1, 3, 2, 1], "Order should be System, C, B, A")

        // 3. Prevent moving system chip (index 0)
        let res3 = moveChip(fromIndex: 0, toIndex: 2)
        runner.assertTrue(!res3, "Moving system chip must be rejected")
        runner.assertEqual(chips.map(\.id), [-1, 3, 2, 1], "Order must remain unchanged")

        // 4. Prevent moving user chip before system chip (target index 0)
        let res4 = moveChip(fromIndex: 2, toIndex: 0)
        runner.assertTrue(!res4, "Moving chip before system chip must be rejected")
        runner.assertEqual(chips.map(\.id), [-1, 3, 2, 1], "Order must remain unchanged")

        // 5. Out of bounds index
        let res5 = moveChip(fromIndex: 1, toIndex: 99)
        runner.assertTrue(!res5, "Out of bounds target must be rejected")
    }
}
