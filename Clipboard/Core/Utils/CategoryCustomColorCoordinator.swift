//
//  CategoryCustomColorCoordinator.swift
//  Clipboard
//
//  Created on 2026/10/22.
//

import AppKit
import Foundation

/// 分类标签自定义颜色系统取色器全局常驻协调器
/// 负责管理 NSColorPanel 生命周期与目标回调，避免因菜单销毁导致选色失效
@MainActor
final class CategoryCustomColorCoordinator: NSObject {
    static let shared = CategoryCustomColorCoordinator()

    private var activeChip: CategoryChip?
    private var onColorChanged: ((String) -> Void)?

    private override init() {
        super.init()

        // 当应用整体失去焦点且主剪贴板窗口已不可见时，联动关闭调色器
        NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            if !WindowManager.shared.isVisible {
                self?.closePanelIfOpen()
            }
        }
    }

    /// 打开系统调色器为指定分类挑选颜色
    /// - Parameters:
    ///   - chip: 当前分类芯片
    ///   - onColorChanged: 颜色实时改变时的回调（传回 16 进制颜色字符串）
    func pickColor(
        for chip: CategoryChip,
        onColorChanged: @escaping (String) -> Void
    ) {
        self.activeChip = chip
        self.onColorChanged = onColorChanged

        let panel = NSColorPanel.shared
        panel.color = chip.displayNSColor
        panel.isContinuous = true
        panel.showsAlpha = false
        panel.setTarget(self)
        panel.setAction(#selector(handleColorPanelChange(_:)))

        // 移除旧观察者，注册关闭通知确保面板关闭时保存最终颜色
        NotificationCenter.default.removeObserver(
            self,
            name: NSWindow.willCloseNotification,
            object: panel
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handlePanelClosed(_:)),
            name: NSWindow.willCloseNotification,
            object: panel
        )

        panel.orderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// 关闭当前系统调色板（如果正处于打开状态）
    func closePanelIfOpen() {
        if NSColorPanel.sharedColorPanelExists {
            let panel = NSColorPanel.shared
            if panel.isVisible {
                panel.orderOut(nil)
                panel.close()
            }
        }
        activeChip = nil
        onColorChanged = nil
    }

    /// 响应系统颜色面板的标准 action
    @objc func changeColor(_ sender: Any?) {
        guard let panel = sender as? NSColorPanel else { return }
        handleColorPanelChange(panel)
    }

    @objc private func handleColorPanelChange(_ sender: NSColorPanel) {
        guard let hex = sender.color.toHexString(includeAlpha: false) else { return }
        onColorChanged?(hex)
    }

    @objc private func handlePanelClosed(_ notification: Notification) {
        guard let panel = notification.object as? NSColorPanel else { return }
        handleColorPanelChange(panel)
        NotificationCenter.default.removeObserver(
            self,
            name: NSWindow.willCloseNotification,
            object: panel
        )
    }
}
