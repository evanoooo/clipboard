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
        // 开关关闭时直接返回：不解码全文，也不跑 markdown 检测，预览固定走纯文本/代码
        guard PasteUserDefaults.enableMarkdownPreview else { return false }
        switch type {
        case .string, .rich:
            return MarkdownDetector.usesMarkdownPreview(
                markdownSource,
                isMarkdown: isMarkdown,
                codeLanguage: detectedCodeLanguage
            )
        default:
            return false
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
