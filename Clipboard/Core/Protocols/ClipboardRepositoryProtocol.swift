//
//  ClipboardRepositoryProtocol.swift
//  Clipboard
//
//  Created on 2026/10/21.
//

import Foundation
import SQLite

/// 剪贴板持久化仓储协议
protocol ClipboardRepositoryProtocol: Sendable {
    /// 获取当前历史记录总条数
    func getTotalCount() async -> Int

    /// 插入一条新记录或更新已有记录时间戳
    func insert(item: PasteboardModel, timestamp: Int64, group: Int) async -> PasteInsertResult

    /// 按主键删除单条记录
    func delete(id: Int64) async

    /// 按表达式条件批量删除
    func delete(filter: Expression<Bool>) async

    /// 撤销并恢复快照数据
    func restore(_ snapshots: [ClipSnapshot]) async -> [Int64]

    /// 清空所有历史记录
    func clearHistory() async throws -> Bool

    /// 更新单条记录
    func update(id: Int64, item: PasteboardModel) async

    /// 更新记录所属分组
    func updateItemGroup(id: Int64, groupId: Int) async -> Bool

    /// 更新记录隐藏状态
    func updateItemHidden(id: Int64, hidden: Bool) async -> Bool

    /// 更新记录自定义别名
    func updateItemAlias(id: Int64, alias: String) async -> Bool

    /// 更新记录标签
    func updateItemTag(id: Int64, expectedTag: String, newTag: String) async -> Bool
}
