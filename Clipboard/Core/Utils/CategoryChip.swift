//
//  CategoryChip.swift
//  Clipboard
//
//  Created by crown on 2025/9/21.
//

import SwiftUI

struct CategoryChip: Identifiable, Equatable, Codable {
    let id: Int
    var name: String
    var colorIndex: Int // 存储颜色在调色板中的索引（当 customHexColor 为 nil 时生效）
    var isSystem: Bool
    /// 自定义 HEX 颜色代码（如 "#FF5500"）；若为 nil 则使用 colorIndex 对应色
    var customHexColor: String? = nil

    private static let semanticPalette: [Color] = [
        .gray,
        .blue,
        .green,
        .purple,
        .red,
        .orange,
        .yellow,
    ]

    static let paletteNSColors: [NSColor] = [
        .systemGray,
        .systemBlue,
        .systemGreen,
        .systemPurple,
        .systemRed,
        .systemOrange,
        .systemYellow,
    ]

    static let palette = paletteNSColors.map { Color(nsColor: $0) }

    static func nsColor(at index: Int) -> NSColor {
        guard index >= 0, index < paletteNSColors.count else {
            return paletteNSColors[0]
        }
        return paletteNSColors[index]
    }

    /// 解析并提供展示用的 NSColor：优先读取 customHexColor，缺省或解析失败回退到 colorIndex 预设色
    var displayNSColor: NSColor {
        if let customHexColor, !customHexColor.isEmpty {
            let hex = customHexColor.trimmingCharacters(in: .whitespacesAndNewlines)
            let color = NSColor(hex: hex)
            return color
        }
        return Self.nsColor(at: colorIndex)
    }

    var color: Color {
        get {
            Color(nsColor: displayNSColor)
        }
        set {
            // 当赋新预设颜色时，清除自定义颜色，恢复使用预设色
            customHexColor = nil
            if let index = Self.palette.firstIndex(of: newValue) {
                colorIndex = index
            } else if let index = Self.semanticPalette.firstIndex(of: newValue) {
                colorIndex = index
            } else {
                colorIndex = 0
            }
        }
    }

    init(
        id: Int,
        name: String,
        colorIndex: Int,
        isSystem: Bool = false,
        customHexColor: String? = nil
    ) {
        self.id = id
        self.name = name
        self.colorIndex = colorIndex
        self.isSystem = isSystem
        self.customHexColor = customHexColor
    }

    init(
        id: Int,
        name: String,
        color: Color,
        isSystem: Bool = false,
        customHexColor: String? = nil
    ) {
        let index: Int
        if let found = Self.palette.firstIndex(of: color) {
            index = found
        } else if let found = Self.semanticPalette.firstIndex(of: color) {
            index = found
        } else {
            index = 0
        }
        self.init(id: id, name: name, colorIndex: index, isSystem: isSystem, customHexColor: customHexColor)
    }

    static let systemChips: [CategoryChip] = [
        .init(
            id: -1,
            name: String(localized: "clipboard"),
            color: .gray,
            isSystem: true
        ),
    ]
}
