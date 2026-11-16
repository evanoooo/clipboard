//
//  SettingWindowController.swift
//  Clipboard
//
//  Created on crown 2025/10/26.
//

import AppKit
import SwiftUI

class SettingWindowController: NSWindowController, NSWindowDelegate {
    private static var instance: SettingWindowController?

    static var isWindowVisible: Bool {
        instance?.window?.isVisible ?? false
    }

    static var shared: SettingWindowController {
        if let instance { return instance }
        let newInstance = SettingWindowController()
        instance = newInstance
        return newInstance
    }

    private let viewModel = SettingViewModel()
    private var isContentAttached = false

    private init() {
        let window = SettingWindow(
            contentRect: NSRect(
                x: 0,
                y: 0,
                width: Const.settingWidth,
                height: Const.settingHeight
            ),
            styleMask: [
                .titled, .closable, .miniaturizable, .fullSizeContentView,
            ],
            backing: .buffered,
            defer: false
        )

        window.level = .normal
        window.center()
        window.isReleasedWhenClosed = false
        window.isRestorable = false
        window.titlebarSeparatorStyle = .none

        if #available(macOS 27, *) {
            window.titlebarAppearsTransparent = false
        } else {
            window.titlebarAppearsTransparent = true
        }

        super.init(window: window)
        window.contentView = nil
        window.delegate = self

        window.onCommandW = { [weak self] in
            self?.hideWindow()
        }

        window.onCommandM = { [weak self] in
            self?.minWindow()
        }
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func ensureContentView() {
        guard let window, !isContentAttached else { return }
        let settingView = SettingView()
            .environment(viewModel)
        window.contentView = NSHostingView(rootView: settingView)
        isContentAttached = true
    }

    private func releaseContentView() {
        window?.contentView = nil
        isContentAttached = false
        StorageAnalysisService.shared.clearTransientCache()
    }

    func toggleWindow() {
        guard let window else { return }

        ensureContentView()
        window.layoutIfNeeded()
        NSApp.activate(ignoringOtherApps: true)

        if window.isMiniaturized {
            window.deminiaturize(nil)
        }

        window.makeKeyAndOrderFront(nil)
    }

    func toggleWindow(page: SettingPage) {
        viewModel.navigateTo(page)
        toggleWindow()
    }

    func hideWindow() {
        window?.orderOut(nil)
        releaseContentView()
    }

    func windowWillClose(_: Notification) {
        releaseContentView()
    }

    func minWindow() {
        guard let window else { return }

        if window.isVisible, !window.isMiniaturized {
            window.miniaturize(nil)
        }
    }
}
