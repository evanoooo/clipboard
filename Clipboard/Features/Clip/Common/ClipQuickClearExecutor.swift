//
//  ClipQuickClearExecutor.swift
//  Clipboard
//
//  Shared quick clear execution logic between Drawer and Floating views.
//

import AppKit
import Foundation

/// 抽屉与悬浮窗共用的快速清理流程：预览 → 确认 → 删除 → HUD。
@MainActor
enum ClipQuickClearExecutor {
    static func perform(_ range: QuickClearRange) {
        Task { @MainActor in
            let store = PasteDataStore.main
            let stats = await store.quickClearStats(for: range)
            guard stats.clearable > 0 else {
                HUDManager.shared.show(
                    icon: NSImage(systemSymbolName: "checkmark.circle", accessibilityDescription: nil),
                    text: String(localized: .quickClearNothing)
                )
                return
            }
            let message = stats.skipped > 0
                ? String(localized: .quickClearMessageSkipped(range.rangeTitle, stats.clearable, stats.skipped))
                : String(localized: .quickClearMessage(range.rangeTitle, stats.clearable))
            guard NSAlert.runConfirm(title: String(localized: .quickClearTitle), message: message) else { return }
            await store.quickClear(since: stats.cutoff)
            HUDManager.shared.show(
                icon: NSImage(systemSymbolName: "trash", accessibilityDescription: nil),
                text: String(localized: .quickClearSucceeded(stats.clearable))
            )
        }
    }
}
