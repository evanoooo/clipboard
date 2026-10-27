//
//  NSAlert+Extension.swift
//  Clipboard
//

import AppKit

extension NSAlert {
    static func appAlert() -> NSAlert {
        let alert = NSAlert()
        alert.icon = NSImage(named: "AppIcon")
        return alert
    }

    /// Shows a warning-style confirm/cancel alert and returns true if the user confirmed.
    /// Suppresses window resign-key events while the alert is running.
    static func runConfirm(title: String, message: String) -> Bool {
        AppEnvironment.shared.suppressResignKey = true
        defer { AppEnvironment.shared.suppressResignKey = false }
        let alert = appAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: String(localized: .commonConfirm))
        alert.addButton(withTitle: String(localized: .commonCancel))
        return alert.runModal() == .alertFirstButtonReturn
    }

    /// 确认删除剪贴板记录。带标签分类时必须二次确认；未带标签且未开启全局确认时直接放行。
    @MainActor
    static func confirmDeleteIfNeeded(for item: PasteboardModel) -> Bool {
        guard item.hasCategoryChip || PasteUserDefaults.delConfirm else {
            return true
        }
        if let chip = item.getGroupChip() {
            return runConfirm(
                title: String(localized: .deleteTaggedTitle),
                message: String(localized: .deleteTaggedMessage(chip.name))
            )
        }
        return runConfirm(
            title: String(localized: .deleteTitle),
            message: String(localized: .deleteMessage)
        )
    }

    /// 确认批量删除剪贴板记录。所选记录包含带标签分类时必须二次确认；均未带标签且未开启全局确认时直接放行。
    @MainActor
    static func confirmDeleteIfNeeded(for items: [PasteboardModel]) -> Bool {
        guard !items.isEmpty else { return true }
        if items.count == 1, let first = items.first {
            return confirmDeleteIfNeeded(for: first)
        }

        let taggedItems = items.filter(\.hasCategoryChip)
        guard !taggedItems.isEmpty || PasteUserDefaults.delConfirm else {
            return true
        }

        if !taggedItems.isEmpty {
            return runConfirm(
                title: String(localized: .deleteTaggedTitle),
                message: String(localized: .deleteMultipleTaggedMessage(taggedItems.count))
            )
        }
        return runConfirm(
            title: String(localized: .deleteTitle),
            message: String(localized: .deleteMessage)
        )
    }

    /// 单行文本输入。`submitted("")` 表示用户清空后确认。
    static func promptText(
        title: String,
        message: String,
        initial: String
    ) -> TextPromptOutcome {
        AppEnvironment.shared.suppressResignKey = true
        defer { AppEnvironment.shared.suppressResignKey = false }

        let alert = appAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: String(localized: .commonConfirm))
        alert.addButton(withTitle: String(localized: .commonCancel))

        let field = NSTextField(string: initial)
        field.frame = NSRect(x: 0, y: 0, width: 260, height: 24)
        alert.accessoryView = field
        alert.window.initialFirstResponder = field

        guard alert.runModal() == .alertFirstButtonReturn else { return .cancelled }
        return .submitted(field.stringValue)
    }
}

enum TextPromptOutcome {
    case cancelled
    case submitted(String)
}
