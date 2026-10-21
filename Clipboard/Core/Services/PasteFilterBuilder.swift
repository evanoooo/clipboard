//
//  PasteFilterBuilder.swift
//  Clipboard
//
//  Created by crown on 2026/3/25.
//

import SQLite

enum PasteFilterBuilder {
    static func buildFilter(
        from criteria: SearchCriteria
    ) -> Expression<Bool>? {
        var clauses: [Expression<Bool>] = []

        // 关键词搜索：与入库侧同一套归一化，再按词 AND
        // （入库文本丢弃了空白与标点，查询不归一化会永远匹配不到）
        if !criteria.keyword.isEmpty {
            let tokens = SearchTextNormalizer.queryTokens(criteria.keyword)
            if tokens.isEmpty {
                // 关键词归一化后为空（纯标点/空白）：与任何入库文本都不可能匹配
                clauses.append(Expression<Bool>(value: false))
            } else {
                for token in tokens {
                    clauses.append(Col.searchText.like("%\(token)%"))
                }
            }
        }

        // 分组筛选
        if !criteria.selectedGroupIds.isEmpty {
            clauses.append(groupFilter(for: criteria.selectedGroupIds))
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
            if !tagValues.isEmpty {
                let tagCondition = tagValues.map { (Col.tag ?? "") == $0 }
                    .reduce(Expression<Bool>(value: false)) { result, condition in
                        result || condition
                    }
                clauses.append(tagCondition)
            }
        }

        // 应用筛选
        if !criteria.selectedAppIDs.isEmpty {
            let appCondition = criteria.selectedAppIDs.map {
                Col.appID == $0
            }
            .reduce(Expression<Bool>(value: false)) { $0 || $1 }
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

    private static func groupFilter(for groupIds: Set<Int>) -> Expression<Bool> {
        groupIds.map { Col.group == $0 }
            .reduce(Expression<Bool>(value: false)) { $0 || $1 }
    }
}
