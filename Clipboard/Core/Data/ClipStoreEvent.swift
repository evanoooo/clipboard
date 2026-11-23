//
//  ClipStoreEvent.swift
//  Clipboard
//
//  存储层领域事件与轻量事件总线：将持久化操作与云同步、延迟 OCR 等上层业务解耦
//

import Foundation
import os

nonisolated enum ClipStoreEvent: Sendable {
    /// 本地主动删除记录（热库 ID 列表 + 全局 unique_id 列表）
    case itemsDeleted(uniqueIds: [String], hotIds: [Int64])
    /// 单条记录的分组发生变更
    case itemGroupUpdated(uniqueId: String, groupId: Int)
}

nonisolated final class ClipStoreEventBus: Sendable {
    static let shared = ClipStoreEventBus()

    private let subscribersLock = OSAllocatedUnfairLock<[@Sendable (ClipStoreEvent) -> Void]>(initialState: [])

    private init() {}

    func subscribe(_ handler: @escaping @Sendable (ClipStoreEvent) -> Void) {
        subscribersLock.withLock { $0.append(handler) }
    }

    func publish(_ event: ClipStoreEvent) {
        let handlers = subscribersLock.withLock { $0 }
        for handler in handlers {
            handler(event)
        }
    }
}
