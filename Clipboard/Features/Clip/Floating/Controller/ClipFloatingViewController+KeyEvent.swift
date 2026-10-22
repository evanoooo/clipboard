//
//  ClipFloatingViewController+KeyEvent.swift
//  Clipboard
//
//  Created by crown on 2026/5/4.
//

import AppKit

extension ClipFloatingViewController {
    // MARK: - Event Handlers

    func keyDownEvent(_ event: NSEvent) -> NSEvent? {
        guard event.window == ClipFloatingWindowController.shared.window else {
            return event
        }

        if [.popover, .chipEditing].contains(focusRegion) {
            return focusedKeyDown(event)
        }

        // 极客键盘流：无论焦点在列表还是搜索框，⌘ + 1~9 均可秒速直达粘贴对应条目
        if let index = quickPasteIndex(for: event) {
            let isAttribute = !KeyCode.hasModifier(event, modifierIndex: PasteUserDefaults.plainTextModifier)
            performQuickPaste(at: index, isAttribute: isAttribute)
            return nil
        }

        if focusRegion == .search {
            return focusedKeyDown(event)
        }

        if KeyCode.shouldTriggerSearch(for: event),
           !floatingContentView.headerView.isSearchFieldFirstResponder {
            floatingContentView.historyView.activateSearchField(with: event.characters)
            return nil
        }

        if handleChipTab(event, viewModel: floatingContentView.topVM) {
            return nil
        }

        if event.modifierFlags.contains(.command) {
            return commandKeyDown(event)
        }

        return actionKeyDown(event)
    }

    private func actionKeyDown(_ event: NSEvent) -> NSEvent? {
        switch event.keyCode {
        case KeyCode.upArrow, KeyCode.downArrow:
            return arrowKeyDown(event)

        case KeyCode.escape:
            return escapeKeyDown()

        case KeyCode.space:
            return spaceKeyDown()

        case KeyCode.return, KeyCode.keypadEnter:
            return returnKeyDown(event)

        case KeyCode.delete, KeyCode.forwardDelete:
            let historyView = floatingContentView.historyView
            historyView.requestDelete(at: historyView.selectedIndex)
            return nil

        default:
            return event
        }
    }

    func flagsChangedEvent(_ event: NSEvent) -> NSEvent? {
        guard event.window == ClipFloatingWindowController.shared.window,
              ClipFloatingWindowController.shared.isVisible,
              floatingContentView.historyView.collectionView.isFirstResponder
        else { return event }

        isQuickPastePressed = KeyCode.isQuickPasteModifierPressed()
        isPlainTextModifierPressed = KeyCode.isModifierPressed(modifierIndex: PasteUserDefaults.plainTextModifier)
        return event
    }

    // MARK: - Key Handlers

    private func focusedKeyDown(_ event: NSEvent) -> NSEvent? {
        switch focusRegion {
        case .popover:
            if event.keyCode == KeyCode.escape {
                let now = CACurrentMediaTime()
                let isDoubleTap = (now - lastEscapeTime) < 0.35
                lastEscapeTime = now
                closePreview()
                if isDoubleTap {
                    WindowManager.shared.dismiss()
                }
                return nil
            }
        case .chipEditing:
            switch event.keyCode {
            case KeyCode.escape:
                let now = CACurrentMediaTime()
                let isDoubleTap = (now - lastEscapeTime) < 0.35
                lastEscapeTime = now
                floatingContentView.headerView.cancelKeyboardEditing()
                focusCollection()
                if isDoubleTap {
                    WindowManager.shared.dismiss()
                }
                return nil
            case KeyCode.return:
                floatingContentView.headerView.commitKeyboardEditing()
                focusCollection()
                return nil
            default:
                return event
            }
        case .search:
            if event.keyCode == KeyCode.escape {
                return searchEscapeKeyDown()
            }
        default:
            break
        }
        return event
    }

    private func arrowKeyDown(_ event: NSEvent) -> NSEvent? {
        guard focusRegion == .collection,
              event.modifierFlags.isDisjoint(with: [.command, .option, .control, .shift])
        else { return event }

        let historyView = floatingContentView.historyView
        let count = historyView.collectionView.numberOfItems(inSection: 0)
        guard count > 0 else { return nil }

        let movesDown = event.keyCode == KeyCode.downArrow
        let selected = historyView.collectionView.selectionIndexPaths
        let anchor = (movesDown ? selected.max() : selected.min())?.item ?? historyView.selectedIndex
        let next = min(max(anchor + (movesDown ? 1 : -1), 0), count - 1)
        if next == anchor {
            NSSound.beep()
        }
        // 离屏选中项也按数据顺序导航，再滚动到目标卡片
        historyView.selectAndScrollTo(index: next)
        historyView.updateSelectedItemBorder()
        return nil
    }

    private func searchEscapeKeyDown() -> NSEvent? {
        let now = CACurrentMediaTime()
        let isDoubleTap = (now - lastEscapeTime) < 0.35
        lastEscapeTime = now

        if isDoubleTap {
            floatingContentView.headerView.clearSearch()
            WindowManager.shared.dismiss()
            return nil
        }

        let searchField = floatingContentView.headerView.searchField
        if !searchField.stringValue.isEmpty {
            floatingContentView.headerView.clearSearch()
        } else {
            let historyView = floatingContentView.historyView
            view.window?.makeFirstResponder(historyView.collectionView)
            historyView.setFocusRegion(.collection)
        }
        return nil
    }

    private func escapeKeyDown() -> NSEvent? {
        let now = CACurrentMediaTime()
        let isDoubleTap = (now - lastEscapeTime) < 0.35
        lastEscapeTime = now

        if isDoubleTap {
            if previewPopover != nil {
                closePreview()
            }
            WindowManager.shared.dismiss()
            return nil
        }

        if previewPopover != nil {
            closePreview()
        } else {
            WindowManager.shared.dismiss()
        }
        return nil
    }

    private func spaceKeyDown() -> NSEvent? {
        guard focusRegion == .collection else { return nil }
        let index = floatingContentView.historyView.selectedIndex
        togglePreview(at: index)
        return nil
    }

    private func returnKeyDown(_ event: NSEvent) -> NSEvent? {
        guard focusRegion == .collection else { return nil }
        let historyView = floatingContentView.historyView
        let isAttribute = !KeyCode.hasModifier(
            event,
            modifierIndex: PasteUserDefaults.plainTextModifier
        )
        let items = historyView.selectedModels
        guard !items.isEmpty else { return nil }
        ClipActionService.shared.pasteMultiple(
            items,
            isAttribute: isAttribute,
            checkPermissions: PasteUserDefaults.pasteDirect,
            showTip: !PasteUserDefaults.pasteDirect
        )
        return nil
    }

    private func commandKeyDown(_ event: NSEvent) -> NSEvent? {
        // 支持 ⌘ + ⇧ + C 一键合并复制多选条目
        if event.modifierFlags.contains(.command),
           event.modifierFlags.contains(.shift),
           event.keyCode == KeyCode.c {
            let historyView = floatingContentView.historyView
            let items = historyView.selectedModels
            guard !items.isEmpty else { return nil }
            ClipActionService.shared.copyMultiple(items)
            HUDManager.shared.show(
                icon: NSImage(systemSymbolName: "doc.on.doc.fill", accessibilityDescription: nil),
                text: "已合并复制 \(items.count) 项"
            )
            WindowManager.shared.dismiss()
            return nil
        }

        guard event.modifierFlags.isDisjoint(with: [.option, .control, .shift]) else { return event }

        let historyView = floatingContentView.historyView
        switch event.keyCode {
        case KeyCode.a:
            guard focusRegion == .collection else { return event }
            historyView.collectionView.selectAll(nil)
            historyView.updateSelectedItemBorder()
            return nil
        case KeyCode.c:
            let items = historyView.selectedModels
            guard !items.isEmpty else { return nil }
            if items.count == 1 {
                historyView.copyItem(at: historyView.selectedIndex)
            } else {
                ClipActionService.shared.copyMultiple(items)
                WindowManager.shared.dismiss()
            }
            return nil
        case KeyCode.e:
            historyView.openEditWindow(at: historyView.selectedIndex)
            return nil
        case KeyCode.r:
            guard let model = historyView.selectedModels.first else { return nil }
            PasteAliasEditor.present(for: model)
            return nil

        case KeyCode.z:
            guard focusRegion == .collection else { return event }
            return handleUndo()

        default:
            return event
        }
    }

    /// ⌘Z：撤销会话内最近一次删除。
    private func handleUndo() -> NSEvent? {
        ClipUndoExecutor.performUndo()
        return nil
    }

    private func handleChipTab(_ event: NSEvent, viewModel: TopBarViewModel) -> Bool {
        guard let direction = HotKeyManager.shared.tabDirection(for: event) else {
            return false
        }

        switch direction {
        case .previous:
            viewModel.selectPreviousChip()
        case .next:
            viewModel.selectNextChip()
        }
        floatingContentView.headerView.updateChipSelection()
        return true
    }

    // MARK: - Quick Paste

    private func quickPasteIndex(for event: NSEvent) -> Int? {
        KeyCode.quickPasteIndex(for: event)
    }

    private func performQuickPaste(at index: Int, isAttribute: Bool = true) {
        let historyView = floatingContentView.historyView
        guard index < historyView.dataList.count else {
            NSSound.beep()
            return
        }
        historyView.selectAndScrollTo(index: index)
        ClipActionService.shared.paste(
            historyView.dataList[index],
            isAttribute: isAttribute,
            checkPermissions: PasteUserDefaults.pasteDirect,
            showTip: !PasteUserDefaults.pasteDirect
        )
    }
}

// MARK: - NSGestureRecognizerDelegate

extension ClipFloatingViewController: NSGestureRecognizerDelegate {
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

        let historyView = floatingContentView.historyView
        let headerView = floatingContentView.headerView
        let footerView = floatingContentView.footerView

        if hitView.isDescendant(of: historyView.collectionView) {
            return false
        }

        if hitView.isDescendant(of: footerView) {
            return false
        }

        if hitView.isDescendant(of: headerView) {
            return !headerView.isExcludedFromFocusGesture(hitView)
        }

        return true
    }
}
