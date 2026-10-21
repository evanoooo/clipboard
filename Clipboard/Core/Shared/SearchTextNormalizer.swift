//
//  SearchTextNormalizer.swift
//  Clipboard
//
//  入库与查询共用的搜索文本归一化，避免"写入时归一化、查询时不归一化"的不匹配。
//

import Foundation

enum SearchTextNormalizer {
    /// 保留字母、数字与符号，丢弃空白和标点；按完整字素处理，避免拆散 Emoji 的连接符、肤色与变体选择符。
    ///
    /// 归一化结果不会包含 LIKE 通配符 `%` 与 `_`（二者分别是 `.otherPunctuation` 与
    /// `.connectorPunctuation`），因此查询侧无需额外转义。
    nonisolated static func normalize(_ raw: String) -> String {
        var output = ""
        output.reserveCapacity(raw.utf8.count)
        for character in raw {
            guard let scalar = character.unicodeScalars.first else { continue }
            switch scalar.properties.generalCategory {
            case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .modifierLetter, .otherLetter,
                 .decimalNumber, .letterNumber, .otherNumber,
                 .mathSymbol, .currencySymbol, .modifierSymbol, .otherSymbol:
                output.append(character)
            default:
                if (scalar.value == 0x23 || scalar.value == 0x2A),
                   character.unicodeScalars.contains(where: { $0.value == 0x20E3 }) {
                    output.append(character)
                }
            }
        }
        return output
    }

    /// 把用户输入拆成用于 AND 匹配的词元。
    ///
    /// 空白分隔后逐词归一化，因此 "hello world" 会同时要求命中 hello 与 world，
    /// 不再受原文中两词是否相邻的限制。归一化后为空的词元（例如纯标点）会被丢弃。
    nonisolated static func queryTokens(_ raw: String) -> [String] {
        var seen = Set<String>()
        var tokens: [String] = []
        for part in raw.split(whereSeparator: \.isWhitespace) {
            let token = normalize(String(part))
            guard !token.isEmpty, seen.insert(token).inserted else { continue }
            tokens.append(token)
        }
        return tokens
    }
}
