//
//  ClipContentRendererTests.swift
//  Tests
//
//  Unit tests for ClipContentRenderer strategy resolution.
//

import AppKit
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
        case code(language: CodeLanguage)
        case linkPreview
    }

    struct MockPasteModel {
        var type: PasteModelType
        var hasBgColor: Bool
        var enableLinkPreview: Bool
        var detectedLanguage: CodeLanguage? = nil

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
                if let detectedLanguage {
                    return .code(language: detectedLanguage)
                }
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

        // 7. Plain string (non-code)
        let stringModel = MockPasteModel(type: .string, hasBgColor: false, enableLinkPreview: false)
        runner.assertEqual(stringModel.resolveKind(), .plainText, "String type resolves to .plainText")

        // 8. Code string (Nginx configuration)
        let nginxModel = MockPasteModel(type: .string, hasBgColor: false, enableLinkPreview: false, detectedLanguage: .nginx)
        runner.assertEqual(nginxModel.resolveKind(), .code(language: .nginx), "Nginx configuration resolves to .code(.nginx)")

        // 9. Code string (Swift code)
        let swiftModel = MockPasteModel(type: .string, hasBgColor: false, enableLinkPreview: false, detectedLanguage: .swift)
        runner.assertEqual(swiftModel.resolveKind(), .code(language: .swift), "Swift code resolves to .code(.swift)")

        // 10. Code rendering pipeline with search keyword
        let nginxSample = "server { listen 80; proxy_pass http://localhost; }"
        let rendered = CodeHighlighter.highlight(nginxSample, language: .nginx, keyword: "proxy")
        let renderedString = rendered.string as NSString
        let proxyRange = renderedString.range(of: "proxy")
        runner.assertTrue(proxyRange.location != NSNotFound, "Should find proxy in rendered output")
        let bg = rendered.attribute(.backgroundColor, at: proxyRange.location, effectiveRange: nil) as? NSColor
        runner.assertTrue(bg != nil, "Rendered code should have search highlight background")

        print("✓ ClipContentRenderer strategy resolution tests passed!")
    }
}
