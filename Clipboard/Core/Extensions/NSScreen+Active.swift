//
//  NSScreen+Active.swift
//  Clipboard
//
//  以鼠标所在屏幕作为"用户当前正在操作的屏幕"，替代仅跟随 key window 的 NSScreen.main。
//

import AppKit

extension NSScreen {
    /// 鼠标所在屏幕；找不到时回退到 main 与首块屏幕
    static var active: NSScreen? {
        let mouse = NSEvent.mouseLocation
        return screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? main ?? screens.first
    }
}
