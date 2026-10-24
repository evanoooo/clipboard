//
//  CodeHighlighter.swift
//  Clipboard
//
//  原生 TextKit 词法着色器：纯 Swift 实现状态机分词，自适应深浅模式并融合搜索高亮
//

import AppKit

/// 纯 Swift 实现的高性能词法高亮引擎
enum CodeHighlighter {
    /// 语法高亮的最大字符长度上限，防止超大型文件卡顿
    static let maxHighlightLength = 30_000

    /// 首屏极速视口高亮阈值（字符数），在 ~0.2ms 内完成，确保滚动与展开绝对满帧
    static let fastViewportLength = 3_500

    /// 为指定代码文本生成带语法高亮与搜索词高亮的 NSAttributedString
    /// - Parameters:
    ///   - text: 待高亮的代码纯文本
    ///   - language: 目标编程或配置语言
    ///   - theme: 颜色与字体主题
    ///   - keyword: 可选的当前搜索过滤关键字（黄色高亮背景）
    /// - Returns: 装配好的 NSAttributedString
    static func highlight(
        _ text: String,
        language: CodeLanguage,
        theme: CodeTheme = CodeTheme(),
        keyword: String? = nil,
        limitLength: Int? = nil
    ) -> NSAttributedString {
        guard !text.isEmpty else {
            return NSAttributedString(string: "", attributes: theme.attributes(for: .plain))
        }

        let rules = CodeLanguageRules.rules(for: language)
        let attributedString = NSMutableAttributedString(
            string: text,
            attributes: theme.attributes(for: .plain)
        )

        // 仅在安全长度阈值内进行词法扫描着色
        let effectiveLimit = min(limitLength ?? maxHighlightLength, maxHighlightLength)
        let scanLength = min(text.count, effectiveLimit)
        let scanEndIndex = text.index(text.startIndex, offsetBy: scanLength)
        let scanSubstring = text[..<scanEndIndex]

        tokenizeAndApply(
            to: attributedString,
            text: scanSubstring,
            fullText: text,
            language: language,
            rules: rules,
            theme: theme
        )

        // 叠加搜索关键字高亮
        if let keyword, !keyword.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            applySearchHighlight(to: attributedString, fullText: text, keyword: keyword)
        }

        return attributedString
    }

    /// 异步后台执行语法高亮，避免超长代码在主线程引起微秒级掉帧
    /// 异步延迟分帧执行完整语法高亮，先让出主线程保证视图首帧满帧展现，再无缝平滑更新
    static func highlightAsync(
        _ text: String,
        language: CodeLanguage,
        theme: CodeTheme = CodeTheme(),
        keyword: String? = nil,
        limitLength: Int? = nil
    ) async -> NSAttributedString {
        await Task.detached(priority: .userInitiated) {
            highlight(
                text,
                language: language,
                theme: theme,
                keyword: keyword,
                limitLength: limitLength
            )
        }.value
    }

    // MARK: - 词法扫描与应用

    private static func tokenizeAndApply(
        to attributedString: NSMutableAttributedString,
        text: Substring,
        fullText: String,
        language: CodeLanguage,
        rules: CodeLanguageRules,
        theme: CodeTheme
    ) {
        var currentIndex = text.startIndex

        while currentIndex < text.endIndex {
            let remainder = text[currentIndex...]

            // 1. 检查多行字符串（例如 Python 三引号 """ 或 '''）
            if let match = matchPrefix(in: remainder, prefixes: rules.multiLineStrings.map(\.open)) {
                let openDelimiter = match
                let closeDelimiter = rules.multiLineStrings.first { $0.open == openDelimiter }?.close ?? openDelimiter
                let tokenStart = currentIndex
                currentIndex = text.index(currentIndex, offsetBy: openDelimiter.count)

                // 扫描直到 closeDelimiter 或文末
                if let closeRange = text[currentIndex...].range(of: closeDelimiter) {
                    currentIndex = closeRange.upperBound
                } else {
                    currentIndex = text.endIndex
                }
                apply(token: .string, from: tokenStart, to: currentIndex, fullText: fullText, in: attributedString, theme: theme)
                continue
            }

            // 2. 检查块注释（/* ... */, <!-- ... -->）
            if let match = matchPrefix(in: remainder, prefixes: rules.blockComments.map(\.open)) {
                let openDelimiter = match
                let closeDelimiter = rules.blockComments.first { $0.open == openDelimiter }?.close ?? openDelimiter
                let tokenStart = currentIndex
                currentIndex = text.index(currentIndex, offsetBy: openDelimiter.count)

                if let closeRange = text[currentIndex...].range(of: closeDelimiter) {
                    currentIndex = closeRange.upperBound
                } else {
                    currentIndex = text.endIndex
                }
                apply(token: .comment, from: tokenStart, to: currentIndex, fullText: fullText, in: attributedString, theme: theme)
                continue
            }

            // 3. 检查单行注释（//, #, -- 等）
            if let match = matchPrefix(in: remainder, prefixes: rules.lineComments) {
                let tokenStart = currentIndex
                currentIndex = text.index(currentIndex, offsetBy: match.count)

                // 扫描到换行符或文末
                while currentIndex < text.endIndex, text[currentIndex] != "\n", text[currentIndex] != "\r" {
                    currentIndex = text.index(after: currentIndex)
                }
                apply(token: .comment, from: tokenStart, to: currentIndex, fullText: fullText, in: attributedString, theme: theme)
                continue
            }

            // 4. 检查常规字符串（"...", '...', `...`）
            if let stringRule = rules.strings.first(where: { remainder.hasPrefix($0.open) }) {
                let tokenStart = currentIndex
                currentIndex = text.index(currentIndex, offsetBy: stringRule.open.count)
                var escaped = false

                while currentIndex < text.endIndex {
                    let char = text[currentIndex]
                    if stringRule.escapes && char == "\\" && !escaped {
                        escaped = true
                        currentIndex = text.index(after: currentIndex)
                        continue
                    }

                    if !escaped && text[currentIndex...].hasPrefix(stringRule.close) {
                        currentIndex = text.index(currentIndex, offsetBy: stringRule.close.count)
                        break
                    }

                    escaped = false
                    currentIndex = text.index(after: currentIndex)
                }
                apply(token: .string, from: tokenStart, to: currentIndex, fullText: fullText, in: attributedString, theme: theme)
                continue
            }

            let currentChar = text[currentIndex]

            // 5. 变量识别（特别是 Nginx / Shell / PHP 中的 $variable 或 ${variable}，以及 Shell 特殊变量 $?, $@, $#, $$, $*, $!, $-）
            if currentChar == "$" {
                let tokenStart = currentIndex
                var nextIndex = text.index(after: currentIndex)

                if nextIndex < text.endIndex && text[nextIndex] == "{" {
                    // 形如 ${variable} 或 ${VAR:-default}
                    if let closeBrace = text[nextIndex...].firstIndex(of: "}") {
                        currentIndex = text.index(after: closeBrace)
                        apply(token: .variable, from: tokenStart, to: currentIndex, fullText: fullText, in: attributedString, theme: theme)
                        continue
                    }
                } else if nextIndex < text.endIndex && "?@#*!$-".contains(text[nextIndex]) {
                    // Shell 特殊单字符变量：$?, $@, $#, $$, $*, $!, $-
                    nextIndex = text.index(after: nextIndex)
                    currentIndex = nextIndex
                    apply(token: .variable, from: tokenStart, to: currentIndex, fullText: fullText, in: attributedString, theme: theme)
                    continue
                } else {
                    // 形如 $host, $1, $remote_addr
                    while nextIndex < text.endIndex {
                        let c = text[nextIndex]
                        if c.isLetter || c.isNumber || c == "_" {
                            nextIndex = text.index(after: nextIndex)
                        } else {
                            break
                        }
                    }
                    if nextIndex > text.index(after: tokenStart) {
                        currentIndex = nextIndex
                        apply(token: .variable, from: tokenStart, to: currentIndex, fullText: fullText, in: attributedString, theme: theme)
                        continue
                    }
                }
            }

            // 6. 数字识别（十六进制 0x..., 浮点数, 整数, 或带单位如 80m, 10s, 1024k）
            if currentChar.isNumber {
                let tokenStart = currentIndex
                var nextIndex = text.index(after: currentIndex)

                // 检查是否为 0x 十六进制
                if currentChar == "0" && nextIndex < text.endIndex && (text[nextIndex] == "x" || text[nextIndex] == "X") {
                    nextIndex = text.index(after: nextIndex)
                    while nextIndex < text.endIndex && text[nextIndex].isHexDigit {
                        nextIndex = text.index(after: nextIndex)
                    }
                } else {
                    // 普通数字及小数点
                    var hasDot = false
                    while nextIndex < text.endIndex {
                        let c = text[nextIndex]
                        if c.isNumber {
                            nextIndex = text.index(after: nextIndex)
                        } else if c == "." && !hasDot {
                            hasDot = true
                            nextIndex = text.index(after: nextIndex)
                        } else if c.isLetter {
                            // 支持配置文件中常见的单位后缀：k, m, g, s, h, d, ms
                            nextIndex = text.index(after: nextIndex)
                        } else {
                            break
                        }
                    }
                }

                currentIndex = nextIndex
                apply(token: .number, from: tokenStart, to: currentIndex, fullText: fullText, in: attributedString, theme: theme)
                continue
            }

            // 7. 单词标识符识别（字母、下划线、以及特定配置或Shell语言允许的破折号）
            if isIdentifierStart(currentChar, language: language) {
                let tokenStart = currentIndex
                var nextIndex = text.index(after: currentIndex)

                while nextIndex < text.endIndex && isIdentifierPart(text[nextIndex], language: language) {
                    nextIndex = text.index(after: nextIndex)
                }

                let word = String(text[tokenStart..<nextIndex])
                currentIndex = nextIndex

                if rules.isKeyword(word) {
                    apply(token: .keyword, from: tokenStart, to: currentIndex, fullText: fullText, in: attributedString, theme: theme)
                } else if rules.isLiteral(word) {
                    apply(token: .literal, from: tokenStart, to: currentIndex, fullText: fullText, in: attributedString, theme: theme)
                } else if rules.uppercaseMeansType && word.first?.isUppercase == true {
                    apply(token: .type, from: tokenStart, to: currentIndex, fullText: fullText, in: attributedString, theme: theme)
                }
                continue
            }

            // 8. 其他字符前进一位
            currentIndex = text.index(after: currentIndex)
        }
    }

    private static func isIdentifierStart(_ c: Character, language: CodeLanguage) -> Bool {
        c.isLetter || c == "_"
    }

    private static func isIdentifierPart(_ c: Character, language: CodeLanguage) -> Bool {
        if c.isLetter || c.isNumber || c == "_" {
            return true
        }
        // Nginx 配置指令、HTML/CSS 标签以及 Shell/Bash 命令（如 apt-get, ssh-keygen）允许中划线
        if (language == .nginx || language == .html || language == .css || language == .bash) && c == "-" {
            return true
        }
        return false
    }

    private static func matchPrefix(in remainder: Substring, prefixes: [String]) -> String? {
        for prefix in prefixes where !prefix.isEmpty {
            if remainder.hasPrefix(prefix) {
                return prefix
            }
        }
        return nil
    }

    private static func apply(
        token: CodeTokenKind,
        from start: String.Index,
        to end: String.Index,
        fullText: String,
        in attributedString: NSMutableAttributedString,
        theme: CodeTheme
    ) {
        let nsRange = NSRange(start..<end, in: fullText)
        guard nsRange.location != NSNotFound, nsRange.length > 0 else { return }
        attributedString.addAttributes(theme.attributes(for: token), range: nsRange)
    }

    // MARK: - 搜索关键字高亮

    private static func applySearchHighlight(
        to mutable: NSMutableAttributedString,
        fullText: String,
        keyword: String
    ) {
        let trimmed = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        let nsString = fullText as NSString
        let options: NSString.CompareOptions = [.caseInsensitive, .diacriticInsensitive, .widthInsensitive]
        var searchRange = NSRange(location: 0, length: nsString.length)

        let highlightAttributes: [NSAttributedString.Key: Any] = [
            .backgroundColor: NSColor.systemYellow.withAlphaComponent(0.65)
        ]

        while searchRange.length > 0 {
            let found = nsString.range(of: trimmed, options: options, range: searchRange, locale: .current)
            guard found.location != NSNotFound else { break }

            mutable.addAttributes(highlightAttributes, range: found)

            let next = found.location + found.length
            guard next < nsString.length else { break }
            searchRange = NSRange(location: next, length: nsString.length - next)
        }
    }
}
