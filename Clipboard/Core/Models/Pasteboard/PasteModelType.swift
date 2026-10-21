//
//  PasteModelType.swift
//  Clipboard
//
//  剪贴板内容的语义类型枚举
//

import AppKit

enum PasteModelType: String, CaseIterable, Sendable {
    case none
    case image
    case string
    case rich
    case file
    case link
    case color

    var string: String {
        switch self {
        case .image: String(localized: "Image")
        case .string, .rich: String(localized: "Text")
        case .color: String(localized: "Color")
        case .link: String(localized: "Link")
        case .file: String(localized: "File")
        default: ""
        }
    }

    var tagValue: String {
        switch self {
        case .none: ""
        case .image: "image"
        case .string: "string"
        case .rich: "rich"
        case .file: "file"
        case .link: "link"
        case .color: "color"
        }
    }

    var iconAndLabel: (icon: String, label: String) {
        switch self {
        case .image:
            ("photo", String(localized: "Image"))
        case .string, .rich:
            ("text.document", String(localized: "Text"))
        case .file:
            ("folder", String(localized: "File"))
        case .link:
            ("link", String(localized: "Link"))
        case .color:
            ("paintpalette", String(localized: "Color"))
        case .none:
            ("", "")
        }
    }
}
