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
    private(set) static var isRunning = false

    /// 面板内快速清理菜单快捷键：⌘⇧⌫（兼容 Delete 与 ForwardDelete）。
    static func matchesShortcut(_ event: NSEvent) -> Bool {
        guard event.keyCode == KeyCode.delete || event.keyCode == KeyCode.forwardDelete else {
            return false
        }
        let relevant: NSEvent.ModifierFlags = [.command, .option, .control, .shift]
        return event.modifierFlags.intersection(relevant) == [.command, .shift]
    }

    static func perform(_ range: QuickClearRange) {
        guard !isRunning else { return }
        isRunning = true
        Task { @MainActor in
            defer { isRunning = false }
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
