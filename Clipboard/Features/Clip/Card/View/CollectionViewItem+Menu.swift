import AppKit

// MARK: - Context Menu

extension CollectionViewItem: ClipItemMenuActionable {
    private var pasteMenuTitle: String {
        if let appName = delegate?.preApp?.localizedName, PasteUserDefaults.pasteDirect {
            String(localized: .pasteToApp(appName))
        } else {
            String(localized: .paste)
        }
    }

    func handleClipPaste() {
        guard let model = item else { return }
        delegate?.paste(model)
    }

    func handleClipPastePlain() {
        guard let model = item else { return }
        delegate?.pastePlain(model)
    }

    func handleClipCopy() {
        guard let model = item else { return }
        delegate?.copy(model)
    }

    func handleClipMergeCopy() {
        if let paths = collectionView?.selectionIndexPaths, paths.count > 1 {
            let items = paths.compactMap { (collectionView?.item(at: $0) as? CollectionViewItem)?.item }
            if !items.isEmpty {
                ClipActionService.shared.copyMultiple(items)
                HUDManager.shared.show(
                    icon: NSImage(systemSymbolName: "doc.on.doc.fill", accessibilityDescription: nil),
                    text: "已合并复制 \(items.count) 项"
                )
                WindowManager.shared.dismiss()
                return
            }
        }
        guard let model = item else { return }
        delegate?.copy(model)
    }

    func handleClipEdit() {
        guard let model = item else { return }
        delegate?.edit(model)
    }

    func handleClipRename() {
        beginAliasEditing()
    }

    func handleClipDelete() {
        guard let model = item, let indexPath = collectionView?.indexPath(for: self) else { return }
        delegate?.delete(model, indexPath: indexPath)
    }

    func handleClipAssignToChip(_ sender: NSMenuItem) {
        guard let model = item, model.group != sender.tag else { return }
        delegate?.assignToChip(model, chipId: sender.tag)
    }

    func handleClipCreateChip() {
        guard let model = item else { return }
        delegate?.createChip(pinning: model)
    }

    func handleClipUnpin() {
        guard let model = item else { return }
        delegate?.assignToChip(model, chipId: -1)
    }

    func handleClipPreview() {
        guard let model = item else { return }
        delegate?.preview(model)
    }

    func handleClipRevealInFinder() {
        guard let paths = item?.cachedFilePaths, !paths.isEmpty else { return }
        NSWorkspace.shared.activateFileViewerSelecting(paths.map { URL(fileURLWithPath: $0) })
    }

    func handleClipOpenInBrowser() {
        guard let model = item, let url = URL(string: model.plainText) else { return }
        NSWorkspace.shared.open(url)
    }

    func handleClipOpenWithDefaultApp() {
        guard let path = item?.cachedFilePaths?.first else { return }
        NSWorkspace.shared.open(URL(fileURLWithPath: path))
    }

    // MARK: - Quick Transforms

    func handleClipFormatJSON() {
        guard let model = item else { return }
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
        guard let model = item else { return }
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

extension CollectionViewItem: NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        guard let model = item else { return }
        delegate?.itemDidRequestSelect(self)
        for item in buildClipItemMenu(for: model, pasteTitle: pasteMenuTitle).items {
            menu.addItem(item)
        }
    }
}
