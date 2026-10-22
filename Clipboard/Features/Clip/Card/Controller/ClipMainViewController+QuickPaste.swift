//
//  ClipMainViewController+QuickPaste.swift
//  Clipboard
//
//  Created by crown on 2026/4/18.
//

import AppKit
import Carbon
import Combine

// MARK: - Quick Paste

extension ClipMainViewController {
    func flagsChangedEvent(_ event: NSEvent) -> NSEvent? {
        guard focusRegion != .popover, focusRegion != .chipEditing, focusRegion != .aliasEditing else {
            return event
        }

        isQuickPastePressed = KeyCode.isQuickPasteModifierPressed()
        isPlainTextModifierPressed = KeyCode.isModifierPressed(modifierIndex: PasteUserDefaults.plainTextModifier)
        return event
    }

    func updateQuickPasteDisplay() {
        let visibleItems = collectionView.visibleItems()
        for case let item as CollectionViewItem in visibleItems {
            guard let indexPath = collectionView.indexPath(for: item) else {
                continue
            }
            item.quickPasteIndex = quickPasteIndex(for: indexPath.item)
        }
    }

    func updatePlainTextIndicatorDisplay() {
        let visibleItems = collectionView.visibleItems()
        for case let item as CollectionViewItem in visibleItems {
            item.showPlainTextIndicator = isPlainTextModifierPressed
        }
    }

    func quickPasteIndex(for index: Int) -> Int? {
        guard isQuickPastePressed, index < 9 else { return nil }
        return index + 1
    }

    func handleQuickPasteShortcut(_ event: NSEvent) -> Int? {
        KeyCode.quickPasteIndex(for: event)
    }

    func performQuickPaste(at index: Int, isAttribute: Bool = true) {
        guard index >= 0 else {
            NSSound.beep()
            return
        }
        let indexPath = IndexPath(item: index, section: 0)
        guard let item = displayedModel(at: indexPath) else {
            NSSound.beep()
            return
        }

        collectionView.deselectItems(at: [selectIndexPath])
        selectIndexPath = indexPath
        collectionView.selectItems(
            at: [selectIndexPath],
            scrollPosition: .centeredHorizontally
        )
        updateSelectedItemBorder()

        ClipActionService.shared.paste(
            item,
            isAttribute: isAttribute,
            checkPermissions: PasteUserDefaults.pasteDirect
        )
    }
}
