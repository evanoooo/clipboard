//
//  ClipUndoStore.swift
//  Clipboard
//
//  唤出内删除撤销栈：只对当前这次弹出有效，窗口重新唤出即清空。
//

import AppKit
import Foundation

/// 一条被删除记录的完整快照（含 sort_order，恢复时原值写回即可回到原位）。
nonisolated struct ClipSnapshot: Sendable {
    let id: Int64
    let uniqueId: String
    let type: String
    let data: Data
    let showData: Data?
    let timestamp: Int64
    let appID: Int64?
    let searchText: String
    let length: Int
    let group: Int
    let tag: String
    let alias: String
    let hidden: Bool
    /// 删除前的显示顺序，恢复时原值写回即可回到原位。
    let sortOrder: Int64

    var payloadBytes: Int {
        data.count + (showData?.count ?? 0)
    }
}

/// 用户可见的「删除」有三种结果，撤销需要分别处理。
nonisolated enum ClipUndoAction: Sendable {
    /// 真实删除：需要把行重新插入。
    case deleted([ClipSnapshot])
    /// 分组内删除：仅把条目移回原分组。
    case ungrouped(ids: [Int64], groupId: Int)
    /// 已固定条目在主列表删除：仅隐藏。
    case hidden(ids: [Int64])
    /// 一次用户操作可能同时触发多种结果（多选删除）。
    indirect case batch([ClipUndoAction])

    var itemCount: Int {
        switch self {
        case let .deleted(snapshots): snapshots.count
        case let .ungrouped(ids, _): ids.count
        case let .hidden(ids): ids.count
        case let .batch(actions): actions.reduce(0) { $0 + $1.itemCount }
        }
    }

    var payloadBytes: Int {
        switch self {
        case let .deleted(snapshots): snapshots.reduce(0) { $0 + $1.payloadBytes }
        case .ungrouped, .hidden: 0
        case let .batch(actions): actions.reduce(0) { $0 + $1.payloadBytes }
        }
    }
}

@MainActor
final class ClipUndoStore {
    static let shared = ClipUndoStore()

    /// 只保留最近若干次操作，避免图片快照长期占用内存。
    /// 栈随窗口唤出清空，这里的上限只是单次唤出内的安全阀。
    private let maxEntries = 20
    private let maxPayloadBytes = 256 * 1024 * 1024

    private var stack: [ClipUndoAction] = []
    private var payloadBytes = 0

    private init() {}

    var canUndo: Bool {
        !stack.isEmpty
    }

    var undoCount: Int {
        stack.count
    }

    func push(_ action: ClipUndoAction) {
        guard action.itemCount > 0 else { return }
        stack.append(action)
        payloadBytes += action.payloadBytes
        evictIfNeeded()
    }

    func pop() -> ClipUndoAction? {
        guard let action = stack.popLast() else { return nil }
        payloadBytes -= action.payloadBytes
        return action
    }

    func removeAll() {
        stack.removeAll()
        payloadBytes = 0
    }

    private func evictIfNeeded() {
        while stack.count > maxEntries || payloadBytes > maxPayloadBytes {
            guard !stack.isEmpty else { break }
            payloadBytes -= stack.removeFirst().payloadBytes
        }
    }
}

@MainActor
extension ClipSnapshot {
    init?(model: PasteboardModel) {
        guard let id = model.id else { return nil }
        self.init(
            id: id,
            uniqueId: model.uniqueId,
            type: model.pasteboardType.rawValue,
            data: model.data,
            showData: model.showData,
            timestamp: model.timestamp,
            appID: model.appID,
            searchText: model.searchText,
            length: model.length,
            group: model.group,
            tag: model.tag,
            alias: model.alias,
            hidden: model.hidden,
            sortOrder: model.sortOrder
        )
    }
}
