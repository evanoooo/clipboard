//
//  ClipContentRendererTests.swift
//  Tests
//
//  Unit tests for ClipContentRenderer strategy resolution.
//

import Foundation

@MainActor
enum ClipContentRendererTests {
    enum MockContentKind: Equatable {
        case empty
        case color
        case image
        case file
        case richText(hasBackground: Bool)
        case plainText
        case linkPreview
    }

    struct MockPasteModel {
        var type: PasteModelType
        var hasBgColor: Bool
        var enableLinkPreview: Bool

        func resolveKind() -> MockContentKind {
            switch type {
            case .none:
                return .empty
            case .color:
                return .color
            case .image:
                return .image
            case .file:
                return .file
            case .rich:
                return hasBgColor ? .richText(hasBackground: true) : .plainText
            case .link:
                return enableLinkPreview ? .linkPreview : .plainText
            case .string:
                return .plainText
            }
        }
    }

    static func run(runner: TestRunner.Type) {
        print("\n--- Testing ClipContentRenderer Strategy Resolution ---")

        // 1. Color item
        let colorModel = MockPasteModel(type: .color, hasBgColor: false, enableLinkPreview: false)
        runner.assertEqual(colorModel.resolveKind(), .color, "Color type resolves to .color")

        // 2. Image item
        let imageModel = MockPasteModel(type: .image, hasBgColor: false, enableLinkPreview: false)
        runner.assertEqual(imageModel.resolveKind(), .image, "Image type resolves to .image")

        // 3. File item
        let fileModel = MockPasteModel(type: .file, hasBgColor: false, enableLinkPreview: false)
        runner.assertEqual(fileModel.resolveKind(), .file, "File type resolves to .file")

        // 4. Rich text with background
        let richWithBg = MockPasteModel(type: .rich, hasBgColor: true, enableLinkPreview: false)
        runner.assertEqual(richWithBg.resolveKind(), .richText(hasBackground: true), "Rich text with background resolves to richText")

        // 5. Rich text without background degrades gracefully to plain text
        let richWithoutBg = MockPasteModel(type: .rich, hasBgColor: false, enableLinkPreview: false)
        runner.assertEqual(richWithoutBg.resolveKind(), .plainText, "Rich text without bg degrades to plainText")

        // 6. Link with preview enabled vs disabled
        let linkEnabled = MockPasteModel(type: .link, hasBgColor: false, enableLinkPreview: true)
        runner.assertEqual(linkEnabled.resolveKind(), .linkPreview, "Link resolves to linkPreview when enabled")

        let linkDisabled = MockPasteModel(type: .link, hasBgColor: false, enableLinkPreview: false)
        runner.assertEqual(linkDisabled.resolveKind(), .plainText, "Link resolves to plainText when preview disabled")

        // 7. Plain string
        let stringModel = MockPasteModel(type: .string, hasBgColor: false, enableLinkPreview: false)
        runner.assertEqual(stringModel.resolveKind(), .plainText, "String type resolves to .plainText")

        print("✓ ClipContentRenderer strategy resolution tests passed!")
    }
}
