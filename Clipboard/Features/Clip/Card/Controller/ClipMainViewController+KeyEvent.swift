//
//  ClipMainViewController+KeyEvent.swift
//  Clipboard
//
//  Created by crown on 2025/9/13.
//

import AppKit
import Combine

// MARK: - Keyboard Events

extension ClipMainViewController: NSGestureRecognizerDelegate {
    func gestureRecognizer(
        _: NSGestureRecognizer,
        shouldAttemptToRecognizeWith event: NSEvent
    ) -> Bool {
        guard
            let hitView = view.window?.contentView?
            .hitTest(event.locationInWindow)
        else {
            return true
        }
        if hitView.isDescendant(of: collectionView) {
            return false
        }

        if hitView.isDescendant(of: topBarView) {
            return hitView === topBarView
        }

        if hitView is NSControl {
            return false
        }

        return true
    }
}

extension ClipMainViewController {
    func keyDownEvent(_ event: NSEvent) -> NSEvent? {
        log.debug(
            """
            keyDown keyCode=\(event.keyCode) modifiers=\(event.modifierFlags.rawValue) \
            focusRegion=\(focusRegion) firstResponder=\(String(describing: view.window?.firstResponder))
            """
        )
        if focusRegion == .popover || focusRegion == .chipEditing || focusRegion == .aliasEditing {
            return handleFocusedKeyEvent(event)
        }

        // 极客键盘流：无论焦点在列表还是搜索框，⌘ + 1~9 均可秒速直达粘贴对应位置卡片
        if let index = handleQuickPasteShortcut(event) {
            let isAttribute = !hasPlainTextModifier(event)
            performQuickPaste(at: index, isAttribute: isAttribute)
            return nil
        }

        if KeyCode.shouldTriggerSearch(for: event),
           !topBarView.searchField.isFirstResponder,
           focusRegion == .collection {
            if let characters = event.characters, !characters.isEmpty {
                topBarView.activateSearch(with: characters)
            }
            setFocusRegion(.search)
            view.window?.makeFirstResponder(topBarView.searchField)
            return nil
        }

        if handleChipTab(event) {
            return nil
        }

        if event.modifierFlags.contains(.command) {
            return handleCommandKeyEvent(event)
        }

        return handleActionKeyEvent(event)
    }

    private func handleFocusedKeyEvent(_ event: NSEvent) -> NSEvent? {
        // 别名内联编辑：按键全部交给字段编辑器，Enter/Esc 由 CardHeadView 自己处理。
        if focusRegion == .aliasEditing {
            return event
        }

        if focusRegion == .popover {
            if event.modifierFlags.contains(.command),
               event.modifierFlags.isDisjoint(with: [.option, .control, .shift]),
               event.keyCode == KeyCode.f {
                closePreviewPopover()
                topBarView.focusSearchField(selectAll: true)
                return nil
            }

            if event.keyCode == KeyCode.escape {
                let now = CACurrentMediaTime()
                let isDoubleTap = (now - lastEscapeTime) < 0.35
                lastEscapeTime = now
                closePreviewPopover()
                if isDoubleTap {
                    WindowManager.shared.dismiss()
                }
                return nil
            }
            return event
        }

        switch event.keyCode {
        case KeyCode.escape:
            let now = CACurrentMediaTime()
            let isDoubleTap = (now - lastEscapeTime) < 0.35
            lastEscapeTime = now
            topBarView.cancelKeyboardEditing()
            setFocusRegion(.collection)
            if isDoubleTap {
                WindowManager.shared.dismiss()
            }
            return nil
        case KeyCode.return:
            topBarView.commitKeyboardEditing()
            setFocusRegion(.collection)
            return nil
        default:
            return event
        }
    }

    private func handleActionKeyEvent(_ event: NSEvent) -> NSEvent? {
        switch event.keyCode {
        case KeyCode.leftArrow, KeyCode.rightArrow:
            return arrowKeyDown(event)
        case KeyCode.escape:
            return escapeKeyDown(event)
        case KeyCode.delete:
            return deleteKeyDown(event)
        case KeyCode.return:
            return returnKeyDown(event)
        case KeyCode.space:
            return spaceKeyDown(event)
        default:
            return event
        }
    }

    private func arrowKeyDown(_ event: NSEvent) -> NSEvent? {
        guard focusRegion == .collection,
              event.modifierFlags.isDisjoint(with: [.command, .option, .control, .shift])
        else { return event }
        guard displayedItemCount > 0 else { return nil }

        let movesRight = event.keyCode == KeyCode.rightArrow
        let selected = collectionView.selectionIndexPaths
        let anchor = (movesRight ? selected.max() : selected.min()) ?? selectIndexPath
        let next = min(max(anchor.item + (movesRight ? 1 : -1), 0), displayedItemCount - 1)
        if next == anchor.item {
            NSSound.beep()
        }
        // 离屏选中项也按数据顺序导航，避免原生布局导航跳到可见边界或末项
        resetSelectIndex(IndexPath(item: next, section: 0))
        return nil
    }

    private func escapeKeyDown(_: NSEvent) -> NSEvent? {
        let now = CACurrentMediaTime()
        let isDoubleTap = (now - lastEscapeTime) < 0.35
        lastEscapeTime = now

        // 快速双击 Esc：无论当前处于何种聚焦/输入/弹窗状态，立即强制隐藏面板
        if isDoubleTap {
            if topBarView.searchField.isFirstResponder {
                topBarView.searchField.clearAllContent()
                topBarView.deactivateSearch()
            }
            _ = topBarView.dismissFilterPopoverIfVisible()
            closePreviewPopover()
            WindowManager.shared.dismiss()
            return nil
        }

        // 单按 Esc：精细化层级逐级退出
        if topBarView.dismissFilterPopoverIfVisible() {
            return nil
        }
        let field = topBarView.searchField
        if field.isFirstResponder {
            if field.suggestionWindow.isVisible {
                field.suggestionWindow.hide()
                return nil
            }
            if topVM.hasInput {
                field.clearAllContent()
            } else {
                topBarView.deactivateSearch()
                view.window?.makeFirstResponder(collectionView)
                setFocusRegion(.collection)
            }
        } else {
            WindowManager.shared.dismiss()
        }
        return nil
    }

    private func spaceKeyDown(_ event: NSEvent) -> NSEvent? {
        guard focusRegion == .collection else { return event }

        guard let item = displayedModel(at: selectIndexPath) else { return nil }
        preview(item)
        return nil
    }

    private func deleteKeyDown(_ event: NSEvent) -> NSEvent? {
        guard focusRegion == .collection else { return event }

        let items = selectedModels
        if items.count > 1 {
            guard NSAlert.confirmDeleteIfNeeded(for: items) else { return nil }
            let minIndex =
                collectionView.selectionIndexPaths.map(\.item).min()
                    ?? selectIndexPath.item
            let countAfterDelete = displayedItemCount - items.count
            if countAfterDelete > 0 {
                let newItem = min(minIndex, countAfterDelete - 1)
                selectIndexPath = IndexPath(item: newItem, section: 0)
            }
            cardVM.deleteMultiple(items)
            return nil
        }

        guard let item = displayedModel(at: selectIndexPath) else { return nil }
        delete(item, indexPath: selectIndexPath)
        return nil
    }

    private func returnKeyDown(_ event: NSEvent) -> NSEvent? {
        guard focusRegion == .collection else { return event }
        let items = selectedModels
        guard !items.isEmpty else { return nil }
        ClipActionService.shared.pasteMultiple(
            items,
            isAttribute: !hasPlainTextModifier(event),
            checkPermissions: PasteUserDefaults.pasteDirect,
            showTip: !PasteUserDefaults.pasteDirect
        )
        return nil
    }

    private func hasPlainTextModifier(_ event: NSEvent) -> Bool {
        KeyCode.hasModifier(
            event,
            modifierIndex: PasteUserDefaults.plainTextModifier
        )
    }

    private func handleCommandKeyEvent(_ event: NSEvent) -> NSEvent? {
        // ⌘ + F：快速激活、聚焦并全选搜索框（无论焦点在列表、搜索输入框自身或弹窗）
        if event.keyCode == KeyCode.f,
           event.modifierFlags.isDisjoint(with: [.option, .control, .shift]) {
            closePreviewPopover()
            topBarView.focusSearchField(selectAll: true)
            return nil
        }

        guard focusRegion == .collection else { return event }

        // 支持 ⌘ + ⇧ + C 一键合并复制多项
        if event.modifierFlags.contains(.command),
           event.modifierFlags.contains(.shift),
           event.keyCode == KeyCode.c {
            return handleMergeCopy()
        }

        guard event.modifierFlags.isDisjoint(with: [
            .option, .control, .shift
        ]) else {
            return event
        }

        switch event.keyCode {
        case KeyCode.a:
            collectionView.selectAll(nil)
            updateSelectedItemBorder()
            return nil

        case KeyCode.c:
            return handleCopy()

        case KeyCode.e:
            return handleEdit()

        case KeyCode.r:
            return handleRename()

        case KeyCode.z:
            return handleUndo()

        default:
            return event
        }
    }

    /// ⌘Z：撤销会话内最近一次删除。文本编辑区域不拦截，交给系统文本撤销。
    private func handleUndo() -> NSEvent? {
        ClipUndoExecutor.performUndo()
        return nil
    }

    private func handleMergeCopy() -> NSEvent? {
        let items = selectedModels
        guard !items.isEmpty else { return nil }
        ClipActionService.shared.copyMultiple(items)
        HUDManager.shared.show(
            icon: NSImage(systemSymbolName: "doc.on.doc.fill", accessibilityDescription: nil),
            text: String(localized: .mergedCopyCount(items.count))
        )
        WindowManager.shared.dismiss()
        return nil
    }

    private func handleCopy() -> NSEvent? {
        let items = selectedModels
        guard !items.isEmpty else { return nil }
        if items.count == 1 {
            copy(items[0])
        } else {
            ClipActionService.shared.copyMultiple(items)
            WindowManager.shared.dismiss()
        }
        return nil
    }

    private func handleEdit() -> NSEvent? {
        guard let item = displayedModel(at: selectIndexPath) else { return nil }
        edit(item)
        return nil
    }

    /// ⌘R：在卡片标题上就地重命名。
    private func handleRename() -> NSEvent? {
        guard displayedModel(at: selectIndexPath) != nil,
              let itemView = collectionView.item(at: selectIndexPath) as? CollectionViewItem
        else { return nil }
        itemView.beginAliasEditing()
        return nil
    }

    private func handleChipTab(_ event: NSEvent) -> Bool {
        guard focusRegion == .collection,
              let direction = HotKeyManager.shared.tabDirection(for: event)
        else { return false }

        switch direction {
        case .previous:
            topVM.selectPreviousChip()
        case .next:
            topVM.selectNextChip()
        }
        topBarView.updateChipSelection()
        return true
    }
}
