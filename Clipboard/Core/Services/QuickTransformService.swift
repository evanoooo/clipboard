//
//  QuickTransformService.swift
//  Clipboard
//
//  快捷格式转换服务：纯文本格式化、JSON 美化、变量命名风格转换
//

import Foundation

enum QuickTransformService: Sendable {
    /// 命名风格转换枚举
    enum CaseStyle: String, CaseIterable, Sendable {
        case camel = "camelCase"
        case pascal = "PascalCase"
        case snake = "snake_case"
        case kebab = "kebab-case"
        case screamingSnake = "UPPER_CASE"

        var displayName: String {
            switch self {
            case .camel: return "camelCase (小驼峰)"
            case .pascal: return "PascalCase (大驼峰)"
            case .snake: return "snake_case (下划线)"
            case .kebab: return "kebab-case (连字符)"
            case .screamingSnake: return "UPPER_CASE (常量大写)"
            }
        }
    }

    // MARK: - JSON 转换

    /// 格式化 JSON 字符串为 2 空格缩进的美化格式
    nonisolated static func formatJSON(_ text: String) -> Result<String, Error> {
        do {
            let formatted = try JSONTransformer.transform(text, action: .format(.two))
            return .success(formatted)
        } catch {
            return .failure(error)
        }
    }

    // MARK: - 命名风格转换

    /// 将文本拆词并转换为指定风格
    nonisolated static func convertCase(_ text: String, to style: CaseStyle) -> String {
        let words = splitWords(text)
        guard !words.isEmpty else { return text }

        switch style {
        case .camel:
            return words[0].lowercased() + words.dropFirst().map { capitalize($0) }.joined()
        case .pascal:
            return words.map { capitalize($0) }.joined()
        case .snake:
            return words.map { $0.lowercased() }.joined(separator: "_")
        case .kebab:
            return words.map { $0.lowercased() }.joined(separator: "-")
        case .screamingSnake:
            return words.map { $0.uppercased() }.joined(separator: "_")
        }
    }

    // MARK: - 辅助词元分词

    private nonisolated static func capitalize(_ word: String) -> String {
        guard let first = word.first else { return word }
        return String(first).uppercased() + word.dropFirst().lowercased()
    }

    nonisolated static func splitWords(_ text: String) -> [String] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        let characters = Array(trimmed)
        var words: [String] = []
        var current = ""

        func flush() {
            if !current.isEmpty {
                words.append(current)
                current = ""
            }
        }

        for i in characters.indices {
            let ch = characters[i]
            if ch == "_" || ch == "-" || ch.isWhitespace {
                flush()
                continue
            }

            let prev = i > characters.startIndex ? characters[i - 1] : nil
            let next = i < characters.index(before: characters.endIndex) ? characters[i + 1] : nil

            var isNewWord = false
            if ch.isUppercase {
                if let prev, !prev.isUppercase {
                    isNewWord = true
                } else if let prev, prev.isUppercase, let next, !next.isUppercase {
                    isNewWord = true
                }
            }

            if isNewWord {
                flush()
            }
            current.append(ch)
        }
        flush()
        return words
    }
}
