//
//  MarkdownDetector.swift
//  Clipboard
//
//  markdown 内容检测：强特征直判 + 普通特征加权累计。
//

import Foundation

nonisolated enum MarkdownDetector {
    /// 检测窗口：只看开头，避免超长文本上的重复扫描
    private static let analysisLimit = 8_000

    /// 围栏代码块：既是 markdown 的高置信特征，也是「文档内嵌代码」的判别依据
    private static let fencedCodeBlockSource = "(?m)^[ ]{0,3}(```|~~~)"
    private nonisolated(unsafe) static let fencedCodeBlock: Regex<AnyRegexOutput>? = try? Regex(fencedCodeBlockSource)

    /// 高置信特征：命中任意一个即判定为 markdown
    private nonisolated(unsafe) static let strongPatterns: [Regex<AnyRegexOutput>] = [
        fencedCodeBlockSource,
        "(?m)^[ ]{0,3}#{1,6}[ \\t]", // ATX 标题
        "(?m)^.+\\n[ ]{0,3}(=+|-+)[ \\t]*$", // Setext 标题
        "(?m)^[ ]*\\|?([ ]*:?-+:?[ ]*\\|)+[ ]*:?-*:?[ ]*$", // 表格分隔行
        "!\\[[^\\]\\n]*\\]\\([^)\\s]+(?:[ \\t]+\\\"[^\\\"]*\\\")?\\)", // 图片
        "(?m)^[ ]*[-*+][ \\t]+\\[[ xX]\\][ \\t]+\\S", // 任务列表
        "(?m)^[ ]*[-*+][ \\t]+\\S.*\\n[ ]*[-*+][ \\t]+\\S", // 多行无序列表
        "(?m)^[ ]*[0-9]+\\.[ \\t]+\\S.*\\n[ ]*[0-9]+\\.[ \\t]+\\S", // 多行有序列表
    ].compactMap { try? Regex($0) }

    /// 普通特征：按权重累计，避免单个低信号标记造成误判
    private nonisolated(unsafe) static let weightedPatterns: [(pattern: Regex<AnyRegexOutput>, score: Int)] = [
        ("(?m)^[ ]*[-*+][ \\t]+\\S", 2), // 无序列表
        ("(?m)^[ ]*[0-9]+\\.[ \\t]+\\S", 2), // 有序列表
        ("(?m)^[ ]*>[ \\t]?\\S", 2), // 引用
        ("(?m)^[ ]{0,3}([-*_])([ \\t]*\\1){2,}[ \\t]*$", 2), // 分割线
        ("(\\*\\*|__)[^*_\\n]+(\\*\\*|__)", 1), // 粗体
        ("`[^`\\n]+`", 1), // 行内代码
        ("\\[[^\\]\\n]+\\]\\([^)\\n]+\\)", 2), // 链接
    ].compactMap { pattern, score in
        guard let regex = try? Regex(pattern) else { return nil }
        return (regex, score)
    }

    /// 保守启发式：高置信特征直接命中；普通特征按权重累计。
    /// 目标是覆盖完整预览需要的图片、列表、标题等场景，同时避免普通文本误判。
    static func detect(_ raw: String) -> Bool {
        let text = sample(raw)
        guard text.contains(where: { !$0.isWhitespace }) else { return false }

        for pattern in strongPatterns where text.contains(pattern) {
            return true
        }

        var score = 0
        for (pattern, weight) in weightedPatterns where text.contains(pattern) {
            score += weight
            if score >= 3 {
                return true
            }
        }
        return false
    }

    /// 围栏代码块是否出现
    static func containsFencedCodeBlock(_ raw: String) -> Bool {
        guard let fencedCodeBlock else { return false }
        return sample(raw).contains(fencedCodeBlock)
    }

    /// 是否走 markdown 渲染。
    ///
    /// 源码里的注释列表、docstring 列表同样会命中 markdown 的列表特征，
    /// 因此识别出代码语言时优先按代码展示；真正的 markdown 文档里
    /// 围栏代码块是强信号，此时仍按 markdown 渲染。
    static func usesMarkdownPreview(
        _ source: String,
        isMarkdown: Bool,
        codeLanguage: CodeLanguage?
    ) -> Bool {
        guard isMarkdown else { return false }
        guard codeLanguage != nil else { return true }
        return containsFencedCodeBlock(source)
    }

    private static func sample(_ raw: String) -> String {
        raw.count > analysisLimit ? String(raw.prefix(analysisLimit)) : raw
    }
}
