//
//  WelcomeWindowController.swift
//  Clipboard
//

import AppKit
import SnapKit
import SwiftUI

@MainActor
final class WelcomeWindowController: NSWindowController {
    private static var instance: WelcomeWindowController?

    static var isWindowVisible: Bool {
        instance?.window?.isVisible ?? false
    }

    static var shared: WelcomeWindowController {
        if let instance { return instance }
        let newInstance = WelcomeWindowController()
        instance = newInstance
        return newInstance
    }

    private var isContentAttached = false

    private init() {
        let window = WelcomeWindow(
            contentRect: NSRect(
                x: 0,
                y: 0,
                width: WelcomeStyle.windowWidth,
                height: WelcomeStyle.windowHeight
            ),
            styleMask: [
                .titled, .closable, .miniaturizable, .fullSizeContentView
            ],
            backing: .buffered,
            defer: false
        )

        window.title = "Clip"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.titlebarSeparatorStyle = .none
        window.backgroundColor = .clear
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.isRestorable = false
        window.collectionBehavior = [.moveToActiveSpace]
        window.level = .normal
        window.hasShadow = false
        window.minSize = NSSize(
            width: WelcomeStyle.windowWidth,
            height: WelcomeStyle.windowHeight
        )
        window.maxSize = window.minSize
        window.standardWindowButton(.zoomButton)?.isEnabled = false

        super.init(window: window)

        window.delegate = self
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func ensureContentView() {
        guard let window, !isContentAttached else { return }
        if #available(macOS 26.0, *) {
            window.isOpaque = false
            let glass = NSGlassEffectView()
            glass.cornerRadius = Const.radius
            let content = NSHostingView(rootView: WelcomeView(glass: true))
            glass.contentView = content
            content.snp.makeConstraints { $0.edges.equalToSuperview() }
            window.contentView = glass
        } else {
            window.contentView = NSHostingView(rootView: WelcomeView())
        }
        isContentAttached = true
    }

    private func releaseContentView() {
        window?.contentView = nil
        isContentAttached = false
    }

    static func showIfNeeded() {
        guard !PasteUserDefaults.welcomeDone else { return }
        shared.show()
    }

    func show() {
        ensureContentView()
        NSApp.activate(ignoringOtherApps: true)
        window?.center()
        window?.makeKeyAndOrderFront(nil)
    }

    func skipWelcome() {
        completeWelcome(showClipboard: false)
    }

    func finishWelcome() {
        completeWelcome(showClipboard: true)
    }

    private func completeWelcome(showClipboard: Bool) {
        PasteUserDefaults.welcomeDone = true
        destroyWindow()

        if showClipboard {
            WindowManager.shared.toggleWindow(frame: NSScreen.main?.frame)
        }
    }

    private func destroyWindow() {
        releaseContentView()
        let win = window
        window = nil
        Self.instance = nil
        win?.delegate = nil
        win?.orderOut(nil)
        win?.close()
        malloc_zone_pressure_relief(malloc_default_zone(), 0)
    }
}

extension WelcomeWindowController: NSWindowDelegate {
    func windowWillClose(_: Notification) {
        PasteUserDefaults.welcomeDone = true
        destroyWindow()
    }
}
