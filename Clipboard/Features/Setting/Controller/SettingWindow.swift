//
//  SettingWindow.swift
//  Clipboard
//
//  Created by crown on 2026/4/18.
//

import AppKit

final class SettingWindow: NSWindow {
    var onCommandW: (() -> Void)?
    var onCommandM: (() -> Void)?

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if super.performKeyEquivalent(with: event) {
            return true
        }

        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard modifiers.contains(.command),
              !modifiers.contains(.option),
              !modifiers.contains(.control)
        else { return false }

        let key = event.charactersIgnoringModifiers?.lowercased() ?? ""
        let isShift = modifiers.contains(.shift)

        if !isShift {
            if key == "w" {
                onCommandW?()
                return true
            }
            if key == "m" {
                onCommandM?()
                return true
            }
        }

        // 标准编辑快捷键支持 (⌘C, ⌘V, ⌘X, ⌘A, ⌘Z, ⌘⇧Z)
        let action: Selector? = switch key {
        case "c": #selector(NSText.copy(_:))
        case "v": #selector(NSText.paste(_:))
        case "x": #selector(NSText.cut(_:))
        case "a": #selector(NSResponder.selectAll(_:))
        case "z": isShift ? Selector(("redo:")) : Selector(("undo:"))
        default: nil
        }

        guard let action else { return false }
        return NSApp.sendAction(action, to: nil, from: nil)
    }

    override func keyDown(with event: NSEvent) {
        if event.modifierFlags.contains(.command),
           event.charactersIgnoringModifiers == "w"
        {
            onCommandW?()
            return
        }

        if event.modifierFlags.contains(.command),
           event.charactersIgnoringModifiers == "m"
        {
            onCommandM?()
            return
        }

        super.keyDown(with: event)
    }
}
