//
//  FloatingCardRowView+Menu.swift
//  Clipboard
//

import AppKit

// MARK: - ClipItemMenuActionable

extension FloatingCardRowView: ClipItemMenuActionable {
    func handleClipPaste() {
        onPaste?()
    }

    func handleClipPastePlain() {
        onPastePlainText?()
    }

    func handleClipCopy() {
        onCopy?()
    }

    func handleClipMergeCopy() {
        onCopy?()
    }

    func handleClipEdit() {
        onEdit?()
    }

    func handleClipRename() {
        onSetAlias?()
    }

    func handleClipDelete() {
        onDelete?()
    }

    func handleClipPreview() {
        onTogglePreview?()
    }

    func handleClipAssignToChip(_ sender: NSMenuItem) {
        guard let model = currentModel, model.group != sender.tag else { return }
        onAssignToChip?(sender.tag)
    }

    func handleClipCreateChip() {
        guard let model = currentModel else { return }
        onCreateChip?(model)
    }

    func handleClipUnpin() {
        onAssignToChip?(-1)
    }

    func handleClipRevealInFinder() {
        guard let paths = currentModel?.cachedFilePaths, !paths.isEmpty else { return }
        NSWorkspace.shared.activateFileViewerSelecting(paths.map { URL(fileURLWithPath: $0) })
    }

    func handleClipOpenInBrowser() {
        guard let model = currentModel, let url = URL(string: model.plainText) else { return }
        NSWorkspace.shared.open(url)
    }

    func handleClipOpenWithDefaultApp() {
        guard let path = currentModel?.cachedFilePaths?.first else { return }
        NSWorkspace.shared.open(URL(fileURLWithPath: path))
    }

    // MARK: - Quick Transforms

    func handleClipFormatJSON() {
        guard let model = currentModel else { return }
        switch QuickTransformService.formatJSON(model.plainText) {
        case let .success(formatted):
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(formatted, forType: .string)
            SoundManager.shared.play(.copy)
            HUDManager.shared.show(
                icon: NSImage(systemSymbolName: "curlybraces", accessibilityDescription: nil),
                text: "JSON 已格式化并复制"
            )
        case .failure:
            HUDManager.shared.show(
                icon: NSImage(systemSymbolName: "exclamationmark.triangle.fill", accessibilityDescription: nil),
                text: "JSON 解析错误，请检查语法"
            )
        }
    }

    private func handleClipConvertCase(_ style: QuickTransformService.CaseStyle) {
        guard let model = currentModel else { return }
        let converted = QuickTransformService.convertCase(model.plainText, to: style)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(converted, forType: .string)
        SoundManager.shared.play(.copy)
        HUDManager.shared.show(
            icon: NSImage(systemSymbolName: "textformat", accessibilityDescription: nil),
            text: "已转换为 \(style.rawValue) 并复制"
        )
    }

    func handleClipConvertCamel() {
        handleClipConvertCase(.camel)
    }

    func handleClipConvertPascal() {
        handleClipConvertCase(.pascal)
    }

    func handleClipConvertSnake() {
        handleClipConvertCase(.snake)
    }

    func handleClipConvertKebab() {
        handleClipConvertCase(.kebab)
    }

    func handleClipConvertScreamingSnake() {
        handleClipConvertCase(.screamingSnake)
    }
}

// MARK: - NSMenuDelegate

extension FloatingCardRowView: NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        guard let model = currentModel else { return }
        let pasteTitle = if let appName = AppEnvironment.shared.previousApp?.localizedName,
                            PasteUserDefaults.pasteDirect {
            String(localized: .pasteToApp(appName))
        } else {
            String(localized: .paste)
        }
        for item in buildClipItemMenu(for: model, pasteTitle: pasteTitle).items {
            menu.addItem(item)
        }
    }
}
