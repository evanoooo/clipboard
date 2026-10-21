//
//  PasteAliasEditor.swift
//  Clipboard
//
//  重命名入口（浮动窗口无标题区，使用弹窗；卡片窗口为标题内联编辑）。
//

import AppKit

@MainActor
enum PasteAliasEditor {
    static func present(for model: PasteboardModel) {
        guard let id = model.id else { return }

        let outcome = NSAlert.promptText(
            title: String(localized: .rename),
            message: String(localized: .aliasHint),
            initial: model.alias.isEmpty ? model.type.string : model.alias
        )

        guard case let .submitted(text) = outcome else { return }
        Task {
            await PasteDataStore.main.updateAlias(id: id, alias: text)
        }
    }
}
