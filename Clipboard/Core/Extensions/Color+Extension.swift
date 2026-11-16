//
//  Color+Extension.swift
//  Clipboard
//
//  Created by crown on 2026/1/14.
//

import SwiftUI

extension Color {
    /// 从 hex 字符串创建 Color
    /// - Parameter hex: 十六进制颜色字符串，支持 "#RRGGBB" 或 "RRGGBB" 格式
    nonisolated init(hex: String) {
        var hexString = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        hexString = hexString.replacing("#", with: "")

        var raw: UInt64 = 0
        Scanner(string: hexString).scanHexInt64(&raw)

        let red, green, blue, alpha: Double
        switch hexString.count {
        case 3:
            red = Double((raw & 0xF00) >> 8) / 15.0
            green = Double((raw & 0x0F0) >> 4) / 15.0
            blue = Double(raw & 0x00F) / 15.0
            alpha = 1.0
        case 4:
            red = Double((raw & 0xF000) >> 12) / 15.0
            green = Double((raw & 0x0F00) >> 8) / 15.0
            blue = Double((raw & 0x00F0) >> 4) / 15.0
            alpha = Double(raw & 0x000F) / 15.0
        case 8:
            red = Double((raw & 0xFF00_0000) >> 24) / 255.0
            green = Double((raw & 0x00FF_0000) >> 16) / 255.0
            blue = Double((raw & 0x0000_FF00) >> 8) / 255.0
            alpha = Double(raw & 0x0000_00FF) / 255.0
        default:
            red = Double((raw & 0xFF0000) >> 16) / 255.0
            green = Double((raw & 0x00FF00) >> 8) / 255.0
            blue = Double(raw & 0x0000FF) / 255.0
            alpha = 1.0
        }

        self.init(red: red, green: green, blue: blue, opacity: alpha)
    }
}
