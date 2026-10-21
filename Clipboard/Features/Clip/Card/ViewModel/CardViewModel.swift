//
//  CardViewModel.swift
//  Clipboard
//
//  Created by crown on 2026/4/17.
//

import AppKit
import Combine

final class CardViewModel {
    private let pd = PasteDataStore.main

    /// 卡片上的一次删除在界面上有三种结果：移出分组、隐藏、真删。
    /// 三种结果都汇总成一条撤销记录，⌘Z 一次回到删除前。
    func deleteMultiple(_ items: [PasteboardModel]) {
        guard !items.isEmpty else { return }
        let isInGroup = CategoryChipStore.shared.selectedChipId != -1

        var toUngroup: [PasteboardModel] = []
        var toHide: [PasteboardModel] = []
        var toPermDelete: [PasteboardModel] = []

        for item in items {
            if isInGroup {
                if item.hidden {
                    toPermDelete.append(item)
                } else {
                    toUngroup.append(item)
                }
            } else if item.group != -1 {
                toHide.append(item)
            } else {
                toPermDelete.append(item)
            }
        }

        // 先把仅从当前视图移除的条目拿掉，再算真删后需要回填多少。
        let viewOnlyIds = Set((toUngroup + toHide).compactMap(\.id))
        if !viewOnlyIds.isEmpty {
            var list = pd.dataList.value
            list.removeAll { viewOnlyIds.contains($0.id ?? -1) }
            pd.updateData(with: list, changeType: .delete)
        }

        var actions: [ClipUndoAction] = []

        // 多选可能跨分组，按原分组分别记录。
        var ungroupByGroup: [Int: [Int64]] = [:]
        for item in toUngroup {
            guard let id = item.id, item.group != -1 else { continue }
            ungroupByGroup[item.group, default: []].append(id)
        }
        for (groupId, ids) in ungroupByGroup {
            actions.append(.ungrouped(ids: ids, groupId: groupId))
            for id in ids {
                pd.updateItemGroup(id: id, groupId: -1)
            }
        }

        let hideIds = toHide.compactMap(\.id)
        if !hideIds.isEmpty {
            actions.append(.hidden(ids: hideIds))
            for id in hideIds {
                pd.updateItemHidden(itemId: id, hidden: true)
            }
        }

        if !toPermDelete.isEmpty {
            let snapshots = toPermDelete.compactMap { ClipSnapshot(model: $0) }
            if !snapshots.isEmpty {
                actions.append(.deleted(snapshots))
            }
            pd.deleteItems(toPermDelete, recordUndo: false)
        }

        ClipUndoStore.shared.push(.batch(actions))
    }

    func delete(_ item: PasteboardModel) {
        guard let id = item.id else { return }

        let isInGroup = CategoryChipStore.shared.selectedChipId != -1

        if isInGroup {
            if item.hidden {
                pd.deleteItems(item)
            } else {
                let group = item.group
                var list = pd.dataList.value
                list.removeAll(where: { $0.id == id })
                pd.updateData(with: list, changeType: .delete)

                pd.updateItemGroup(id: id, groupId: -1)
                ClipUndoStore.shared.push(.ungrouped(ids: [id], groupId: group))
            }
        } else if item.group != -1 {
            var list = pd.dataList.value
            list.removeAll(where: { $0.id == id })
            pd.updateData(with: list, changeType: .delete)

            pd.updateItemHidden(itemId: id, hidden: true)
            ClipUndoStore.shared.push(.hidden(ids: [id]))
        } else {
            pd.deleteItems(item)
        }
    }
}
