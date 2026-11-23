//
//  NSColor+Extension.swift
//  clipboard
//
//  Created by crown on 2025/9/12.
//

import AppKit
import Cocoa

extension NSColor {
    convenience init(hex: String) {
        var hexString = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        hexString = hexString.replacing("#", with: "")

        var raw: UInt64 = 0
        Scanner(string: hexString).scanHexInt64(&raw)

        let red, green, blue, alpha: CGFloat
        switch hexString.count {
        case 3:
            red = CGFloat((raw & 0xF00) >> 8) / 15.0
            green = CGFloat((raw & 0x0F0) >> 4) / 15.0
            blue = CGFloat(raw & 0x00F) / 15.0
            alpha = 1.0
        case 4:
            red = CGFloat((raw & 0xF000) >> 12) / 15.0
            green = CGFloat((raw & 0x0F00) >> 8) / 15.0
            blue = CGFloat((raw & 0x00F0) >> 4) / 15.0
            alpha = CGFloat(raw & 0x000F) / 15.0
        case 8:
            red = CGFloat((raw & 0xFF00_0000) >> 24) / 255.0
            green = CGFloat((raw & 0x00FF_0000) >> 16) / 255.0
            blue = CGFloat((raw & 0x0000_FF00) >> 8) / 255.0
            alpha = CGFloat(raw & 0x0000_00FF) / 255.0
        default:
            red = CGFloat((raw & 0xFF0000) >> 16) / 255.0
            green = CGFloat((raw & 0x00FF00) >> 8) / 255.0
            blue = CGFloat(raw & 0x0000FF) / 255.0
            alpha = 1.0
        }

        self.init(red: red, green: green, blue: blue, alpha: alpha)
    }

    /// 将 NSColor 转为十六进制字符串 (#RRGGBB 或 #RRGGBBAA)
    /// - Parameter includeAlpha: 是否包含 alpha 分量，默认 false
    /// - Returns: 类似 "#FF3366" 或 "#FF3366CC"
    func toHexString(includeAlpha: Bool = false) -> String? {
        guard let rgbColor = usingColorSpace(.sRGB) else { return nil }

        let channels = includeAlpha
            ? [rgbColor.redComponent, rgbColor.greenComponent, rgbColor.blueComponent, rgbColor.alphaComponent]
            : [rgbColor.redComponent, rgbColor.greenComponent, rgbColor.blueComponent]
        return "#" + channels.map { component in
            let byte = Int(max(0, min(255, lround(Double(component) * 255.0))))
            let hex = String(byte, radix: 16, uppercase: true)
            return byte < 16 ? "0\(hex)" : hex
        }.joined()
    }
}
