//
//  ClipMaintenanceCoordinator.swift
//  Clipboard
//
//  数据维护相关的弹窗确认与 UI 交互协调器，解除数据层对 AppKit 窗口与弹窗的依赖
//

import AppKit
import Combine
import Foundation

@MainActor
enum ClipMaintenanceCoordinator {
    /// 确认并清理超出新期限的记录；设置仅由调用方在成功后保存
    static func confirmHistoryLimit(_ timeUnit: HistoryTimeUnit) async -> Bool {
        guard let cutoff = timeUnit.cutoffTimestamp() else { return true }
        let store = PasteDataStore.main
        do {
            guard try await store.hasExpiredHistory(before: cutoff) else { return true }
            guard SettingWindowController.isWindowVisible,
                  let window = SettingWindowController.shared.window else {
                return false
            }

            let alert = NSAlert.appAlert()
            alert.alertStyle = .warning
            alert.messageText = String(localized: .generalHistoryLimitConfirmTitle)
            alert.informativeText = String(localized: .generalHistoryLimitConfirmMessage)
            alert.addButton(withTitle: String(localized: .commonCancel))
            let deleteButton = alert.addButton(withTitle: String(localized: .delete))
            deleteButton.hasDestructiveAction = true
            guard await alert.beginSheetModal(for: window) == .alertSecondButtonReturn else {
                return false
            }

            try await store.deleteExpiredHistory(before: cutoff)
            return true
        } catch {
            Log.database.error("应用历史保留期限失败：\(error)")
            if SettingWindowController.isWindowVisible,
               let window = SettingWindowController.shared.window {
                let alert = NSAlert.appAlert()
                alert.alertStyle = .warning
                alert.messageText = String(localized: .generalHistoryLimitFailed)
                alert.addButton(withTitle: String(localized: .commonConfirm))
                await alert.beginSheetModal(for: window)
            }
            return false
        }
    }

    /// 弹出确认对话框并执行历史清空
    static func clearAllData() {
        let store = PasteDataStore.main
        guard !store.clearingHistory.value else { return }

        Task { @MainActor in
            let (normalCount, pinnedCount) = await store.getHistoryStats()
            let alert = NSAlert.appAlert()
            alert.alertStyle = .warning
            alert.messageText = String(localized: .clearHistoryAlertTitle)

            if pinnedCount > 0 {
                alert.informativeText = String(localized: .clearHistoryMessageWithPinned(normalCount, pinnedCount))
            } else {
                alert.informativeText = String(localized: .clearHistoryMessageNormalOnly(normalCount))
            }

            alert.addButton(withTitle: String(localized: .commonCancel))
            let deleteButton = alert.addButton(withTitle: String(localized: .clearHistoryButton))
            deleteButton.hasDestructiveAction = true

            var checkbox: NSButton?
            if pinnedCount > 0 {
                let cb = NSButton(
                    checkboxWithTitle: String(localized: .clearHistoryIncludePinned),
                    target: nil,
                    action: nil
                )
                cb.state = .off
                cb.frame = NSRect(x: 0, y: 0, width: 340, height: 22)
                alert.accessoryView = cb
                checkbox = cb
            }

            let response: NSApplication.ModalResponse
            if SettingWindowController.isWindowVisible,
               let window = SettingWindowController.shared.window {
                response = await alert.beginSheetModal(for: window)
            } else {
                response = alert.runModal()
            }

            guard response == .alertSecondButtonReturn else { return }

            let includePinned = checkbox?.state == .on
            do {
                let reclaimed = try await store.performClearHistory(includePinned: includePinned)
                if reclaimed {
                    showClearHistoryResult(String(localized: .clearHistorySuccess), style: .informational)
                } else {
                    showClearHistoryResult(String(localized: .clearHistorySpaceFailed))
                }
            } catch {
                Log.database.error("清空历史失败：\(error)")
                showClearHistoryResult(String(localized: .clearHistoryFailed))
            }
        }
    }

    private static func showClearHistoryResult(_ message: String, style: NSAlert.Style = .warning) {
        Task { @MainActor in
            let alert = NSAlert.appAlert()
            alert.alertStyle = style
            alert.messageText = message
            alert.addButton(withTitle: String(localized: .commonConfirm))
            if SettingWindowController.isWindowVisible,
               let window = SettingWindowController.shared.window {
                _ = await alert.beginSheetModal(for: window)
            } else {
                alert.runModal()
            }
        }
    }
}
