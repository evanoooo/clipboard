//
//  CodeTheme.swift
//  Clipboard
//
//  词法高亮主题：定义 Token 语义与自适应深浅外观的 TextKit 渲染属性
//

import AppKit

/// 代码词法 Token 类型枚举
enum CodeTokenKind: Sendable, Hashable {
    case plain        // 普通正文/标点符号
    case keyword      // 语言关键字（if, func, server, location 等）
    case directive    // 配置指令（如 Nginx proxy_pass, listen 等）
    case type         // 类型名称（首字母大写等）
    case variable     // 变量（如 Nginx 的 $host, $uri 等）
    case string       // 字符串字面量（"..." 或 '...'）
    case number       // 数字字面量（0x1f, 1024, 80m 等）
    case comment      // 注释（# 或 // 或 /* ... */）
    case literal      // 特殊布尔或开关字面量（true, false, on, off）
}

/// 语法高亮主题配置
struct CodeTheme: Sendable {
    let fontSize: CGFloat
    let fontName: String?

    init(fontSize: CGFloat = 12, fontName: String? = nil) {
        self.fontSize = fontSize
        self.fontName = fontName
    }

    /// 等宽字体，自适应当前系统配置
    var monospacedFont: NSFont {
        if let fontName, let customFont = NSFont(name: fontName, size: fontSize) {
            return customFont
        }
        return NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
    }

    /// 粗体等宽字体
    var boldMonospacedFont: NSFont {
        NSFont.monospacedSystemFont(ofSize: fontSize, weight: .semibold)
    }

    /// 依据 macOS 语义动态色彩映射 Token 颜色，天然自适应深色/浅色模式
    func color(for token: CodeTokenKind) -> NSColor {
        switch token {
        case .plain:
            return .labelColor
        case .keyword:
            return .systemPurple
        case .directive:
            return .systemIndigo
        case .type:
            return .systemTeal
        case .variable:
            return .systemOrange
        case .string:
            return .systemRed
        case .number:
            return .systemBlue
        case .comment:
            return .secondaryLabelColor
        case .literal:
            return .systemPink
        }
    }

    /// 生成对应 Token 的 TextKit 属性字典
    func attributes(for token: CodeTokenKind) -> [NSAttributedString.Key: Any] {
        [
            .font: monospacedFont,
            .foregroundColor: color(for: token)
        ]
    }
}
