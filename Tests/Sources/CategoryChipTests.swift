//
//  CategoryChipTests.swift
//  Tests
//
//  Unit tests for CategoryChip custom color functionality and JSON backward compatibility.
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
}
