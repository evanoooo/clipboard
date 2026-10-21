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
    case linkPreview
}

enum ClipContentRenderer {
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
            return .plainText
        }
    }

    /// Computes unified highlighted attributed string for text-based items.
    static func resolveText(
        for model: PasteboardModel,
        keyword: String,
        isRich: Bool
    ) -> NSAttributedString {
        if isRich {
            return model.highlightedRichText(keyword: keyword)
        } else {
            return keyword.isEmpty
                ? model.plainTextAttributedString
                : model.highlightedNSAttributedString(keyword: keyword)
        }
    }
}
