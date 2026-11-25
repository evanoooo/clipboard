//
//  QuickClearRange.swift
//  Clipboard
//

import Foundation
import SQLite

/// 快速清理的时间范围。只清理普通流水（group == -1），带标签/固定条目始终跳过。
nonisolated enum QuickClearRange: Int, CaseIterable, Sendable {
    case thirtyMinutes = 30
    case oneHour = 60
    case threeHours = 180
    case oneDay = 1440

    var minutes: Int { rawValue }

    /// 截止时间戳（秒），timestamp >= cutoff 的条目属于范围内。
    func cutoff(now: Date = .now) -> Int64 {
        Int64(now.timeIntervalSince1970) - Int64(minutes * 60)
    }

    /// 范围内可清理条目
    static func clearable(since cutoff: Int64) -> SQLite.Expression<Bool> {
        Col.timestamp >= cutoff && Col.group == -1
    }

    /// 范围内被跳过（带标签/固定）条目
    static func skipped(since cutoff: Int64) -> SQLite.Expression<Bool> {
        Col.timestamp >= cutoff && Col.group != -1
    }
}
