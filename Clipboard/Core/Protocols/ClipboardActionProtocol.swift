//
//  ClipboardActionProtocol.swift
//  Clipboard
//
//  Created on 2026/10/21.
//

import AppKit
import Foundation

/// 剪贴板动作抽象协议（复制、粘贴到前台应用等）
@MainActor
protocol ClipboardActionProtocol: AnyObject {
    /// 粘贴单项到前台应用
    func paste(
        _ item: PasteboardModel,
        isAttribute: Bool,
        checkPermissions: Bool,
        showTip: Bool
    )

    /// 批量粘贴多项到前台应用
    func pasteMultiple(
        _ items: [PasteboardModel],
        isAttribute: Bool,
        checkPermissions: Bool,
        showTip: Bool
    )

    /// 复制单项至系统剪贴板
    func copy(
        _ item: PasteboardModel,
        isAttribute: Bool,
        showTip: Bool
    )

    /// 批量复制多项至系统剪贴板
    func copyMultiple(
        _ items: [PasteboardModel],
        isAttribute: Bool
    )
}
