//
//  PasteboardModel+Markdown.swift
//  Clipboard
//
//  markdown 内容检测与渲染入口
//

import AppKit
import Foundation

extension PasteboardModel {
    var usesMarkdownPreview: Bool {
        switch type {
        case .string, .rich:
            MarkdownDetector.usesMarkdownPreview(
                markdownSource,
                isMarkdown: isMarkdown,
                codeLanguage: detectedCodeLanguage
            )
        default:
            false
        }
    }

    var markdownSource: String {
        if pasteboardType == .rtf || pasteboardType == .rtfd {
            return NSAttributedString(with: data, type: pasteboardType)?.string ?? ""
        }
        return String(data: data, encoding: .utf8) ?? attributeString.string
    }

    var isMarkdown: Bool {
        if let cachedIsMarkdown {
            return cachedIsMarkdown
        }
        let result = MarkdownDetector.detect(markdownSource)
        cachedIsMarkdown = result
        return result
    }
}
