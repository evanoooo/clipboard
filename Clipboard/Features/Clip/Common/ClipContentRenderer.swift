//
//  ClipContentRenderer.swift
//  Clipboard
//
//  Unified content rendering strategy and resolution pipeline for Card and Floating views.
//

import AppKit

enum ClipContentKind: Equatable {
    case empty
    case color
    case image
    case file
    case richText(hasBackground: Bool)
    case plainText
    case code(language: CodeLanguage)
    case linkPreview
}

enum ClipContentRenderer {
    /// 搜索关键字高亮结果缓存（防止快速输入或滚动时重复构建 AttributedString）
    private static let keywordHighlightCache: NSCache<NSString, NSAttributedString> = {
        let cache = NSCache<NSString, NSAttributedString>()
        cache.countLimit = 64
        return cache
    }()

    /// Resolves high-level semantic content kind from model properties and preferences.
    static func resolveKind(for model: PasteboardModel) -> ClipContentKind {
        switch model.type {
        case .none:
            return .empty
        case .color:
            return .color
        case .image:
            return .image
        case .file:
            return .file
        case .rich:
            return model.hasBgColor ? .richText(hasBackground: true) : .plainText
        case .link:
            return PasteUserDefaults.enableLinkPreview ? .linkPreview : .plainText
        case .string:
            if let language = model.detectedCodeLanguage {
                return .code(language: language)
            }
            return .plainText
        }
    }

    /// 卡片展示的最大高亮字符数（卡片可视区域仅展示前十几行，超出的部分完全在卡片裁剪区外）
    static let cardHighlightLimit = 3_500

    /// Computes unified highlighted attributed string for text-based items.
    static func resolveText(
        for model: PasteboardModel,
        keyword: String,
        isRich: Bool,
        isCardSnippet: Bool = false
    ) -> NSAttributedString {
        let trimmedKeyword = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedKeyword.isEmpty {
            let cacheKey = "\(model.uniqueId):\(trimmedKeyword):\(isRich):\(isCardSnippet)" as NSString
            if let cached = keywordHighlightCache.object(forKey: cacheKey) {
                return cached
            }
        }

        let result: NSAttributedString
        if isRich {
            result = model.highlightedRichText(keyword: keyword)
        } else {
            if let language = model.detectedCodeLanguage {
                let limit = isCardSnippet ? cardHighlightLimit : nil

                if trimmedKeyword.isEmpty {
                    if let cached = model.cachedHighlightedCode {
                        return cached
                    }
                    let highlighted = CodeHighlighter.highlight(
                        model.attributeString.string,
                        language: language,
                        keyword: nil,
                        limitLength: limit
                    )
                    if !isCardSnippet || model.attributeString.string.count <= cardHighlightLimit {
                        model.cachedHighlightedCode = highlighted
                    }
                    return highlighted
                } else {
                    result = CodeHighlighter.highlight(
                        model.attributeString.string,
                        language: language,
                        keyword: trimmedKeyword,
                        limitLength: limit
                    )
                }
            } else {
                result = trimmedKeyword.isEmpty
                    ? model.plainTextAttributedString
                    : model.highlightedNSAttributedString(keyword: keyword)
            }
        }

        if !trimmedKeyword.isEmpty {
            let cacheKey = "\(model.uniqueId):\(trimmedKeyword):\(isRich):\(isCardSnippet)" as NSString
            keywordHighlightCache.setObject(result, forKey: cacheKey)
        }

        return result
    }
}
