//
//  PasteFilterBuilder.swift
//  Clipboard
//
//  Created by crown on 2026/3/25.
//

import Foundation
import SQLite

enum PasteFilterBuilder {
    static func buildFilter(
        from criteria: SearchCriteria
    ) -> Expression<Bool>? {
        var clauses: [Expression<Bool>] = []

        // 关键词搜索：优先使用 SQLite FTS5 trigram 倒排索引（>=3 字符）；
        // 当 token 长度 < 3 字符时自动优雅降级为 LIKE 模式，保证 100% 检索准确度与秒级响应。
        if !criteria.keyword.isEmpty {
            let tokens = SearchTextNormalizer.queryTokens(criteria.keyword)
            if tokens.isEmpty {
                // 关键词归一化后为空（纯标点/空白）：与任何入库文本都不可能匹配
                clauses.append(Expression<Bool>(value: false))
            } else {
                let canUseFTS = tokens.allSatisfy { $0.count >= 3 }
                if canUseFTS {
                    let matchClauses = tokens.map { token in
                        let escaped = token.replacingOccurrences(of: "\"", with: "\"\"")
                        return "\"\(escaped)\""
                    }
                    let matchString = matchClauses.joined(separator: " AND ")
                    clauses.append(Expression<Bool>(
                        "id IN (SELECT rowid FROM clip_fts WHERE clip_fts MATCH ?)",
                        [matchString]
                    ))
                } else {
                    for token in tokens {
                        // 正文命中或别名命中均可；NULL 别名用空串参与比较，避免三值逻辑产出 NULL。
                        let pattern = "%\(token)%"
                        clauses.append(
                            Col.searchText.like(pattern)
                                || (Col.aliasSearch ?? "").like(pattern)
                        )
                    }
                }
            }
        }

        // 分组筛选
        if !criteria.selectedGroupIds.isEmpty,
           let group = orJoined(criteria.selectedGroupIds.sorted().map { Col.group == $0 }) {
            clauses.append(group)
        } else {
            clauses.append(Col.hidden == 0)
        }

        // 类型筛选
        if !criteria.selectedTypes.isEmpty {
            var tagValues: [String] = []
            for type in criteria.selectedTypes {
                let value = type.tagValue
                if !value.isEmpty {
                    tagValues.append(value)
                }
            }
            if let tagCondition = orJoined(tagValues.sorted().map { (Col.tag ?? "") == $0 }) {
                clauses.append(tagCondition)
            }
        }

        // 应用筛选
        if let appCondition = orJoined(criteria.selectedAppIDs.sorted().map { Col.appID == $0 }) {
            clauses.append(appCondition)
        }

        // 日期筛选
        if let dateFilter = criteria.selectedDateFilter {
            let (start, end) = dateFilter.timestampRange()
            if let endTimestamp = end {
                let dateCondition = Col.timestamp >= start && Col.timestamp < endTimestamp
                clauses.append(dateCondition)
            } else {
                let dateCondition = Col.timestamp >= start
                clauses.append(dateCondition)
            }
        }

        return clauses.reduce(nil) { partial, next in
            if let existing = partial {
                return existing && next
            }
            return next
        }
    }

    /// 不能用 `Expression<Bool>(value: false)` 作为 OR 起点：
    /// 生成的 `(0 OR "group" = 3)` 会让 SQLite 放弃 idx_group_order，
    /// 退化为按 idx_sort_order 的整表扫描（569 MB 库实测 ~900 ms）。
    private static func orJoined(_ conditions: [Expression<Bool>]) -> Expression<Bool>? {
        guard let first = conditions.first else { return nil }
        return conditions.dropFirst().reduce(first) { $0 || $1 }
    }
}
