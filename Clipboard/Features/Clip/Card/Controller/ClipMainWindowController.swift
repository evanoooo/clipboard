//
//  ClipMainWindowController.swift
//  clip
//
//  Created by crown on 2025/7/23.
//

import AppKit
import Combine
import Darwin

final class ClipMainWindowController: NSWindowController {
    private(set) static var isInstanceLoaded = false
    static let shared = ClipMainWindowController()

    private var targetVisible = false
    private var isDismissing = false

    private var slideAnimationGeneration = 0

    var isVisible: Bool {
        targetVisible
    }

    private let dataStore = PasteDataStore.main

    init() {
        let initialWidth = NSScreen.main?.frame.width ?? Const.defaultHeight
        let panel = ClipWindowView(
            contentRect: NSRect(
                x: 0,
                y: 0,
                width: initialWidth,
                height: Const.defaultHeight
            ),
            styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.contentViewController = ClipMainViewController()
        super.init(window: panel)
        Self.isInstanceLoaded = true
        setupWindow()
        pauseObserving()
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setupWindow() {
        guard let win = window as? ClipWindowView else { return }

        win.delegate = self

        win.hasShadow = false
        win.configureCommonSettings()

        win.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
    }

    func resetState() {
        (contentViewController as? ClipMainViewController)?.resetState()
    }

    func pauseObserving() {
        (contentViewController as? ClipMainViewController)?.pauseObserving()
    }

    func releaseVisibleCellPayloads() {
        (contentViewController as? ClipMainViewController)?.releaseVisibleCellPayloads()
    }

    func resumeObserving() {
        (contentViewController as? ClipMainViewController)?.resumeObserving()
    }

    func configureWindowSharing() {
        guard let win = window as? ClipWindowView else { return }
        win.configureWindowSharing(
            showDuringScreenShare: PasteUserDefaults.showDuringScreenShare
        )
    }

    func toggleWindow(
        _ frame: NSRect? = nil,
        _ completionHandler: (@MainActor () -> Void)? = nil
    ) {
        if targetVisible && !(window?.isVisible ?? false) {
            targetVisible = false
            isDismissing = false
        }

        if targetVisible {
            dismiss(completionHandler)
        } else {
            show(in: frame)
        }
    }
}

extension ClipMainWindowController {
    func dismiss(_ completionHandler: (@MainActor () -> Void)? = nil) {
        guard let window, window.isVisible else {
            targetVisible = false
            isDismissing = false
            completionHandler?()
            return
        }
        guard !isDismissing else {
            completionHandler?()
            return
        }
        targetVisible = false
        isDismissing = true
        CategoryCustomColorCoordinator.shared.closePanelIfOpen()
        // 窗口一隐藏就丢弃撤销记录：下次唤出不应再能恢复上一次的删除。
        ClipUndoStore.shared.removeAll()
        animateContent(visible: false) { [weak self] in
            defer { completionHandler?() }
            guard let self else { return }
            self.isDismissing = false
            self.window?.setIsVisible(false)
            if #unavailable(macOS 15.0) {
                AppEnvironment.shared.previousApp?.activate(options: [])
            }
            self.window?.orderOut(nil)
            self.pauseObserving()
            malloc_zone_pressure_relief(malloc_default_zone(), 0)
        }
    }

    func show(in frame: NSRect?) {
        guard let window else { return }
        isDismissing = false
        targetVisible = true
        let initiallyHidden = !window.isVisible

        if initiallyHidden {
            resumeObserving()
            let screenFrame = frame ?? NSScreen.active?.frame ?? .zero
            AppEnvironment.shared.previousApp = NSWorkspace.shared.frontmostApplication
            let visibleFrame = NSRect(
                x: screenFrame.minX, y: screenFrame.minY,
                width: screenFrame.width, height: Const.defaultHeight
            )
            window.contentViewController?.view.setFrameOrigin(.zero)
            window.setFrame(visibleFrame, display: false)
            window.contentViewController?.view.layoutSubtreeIfNeeded()
        }

        // 显示窗口前安装动画，避免首帧闪现
        animateContent(visible: true, initiallyHidden: initiallyHidden) { [weak self] in
            self?.suppressSearchFocusRing(false)
        }
        window.makeKeyAndOrderFront(nil)
        if #unavailable(macOS 15.0) {
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    /// 窗口已在其他屏幕或 Space 可见时返回 true，此时应迁移到目标屏幕而不是隐藏
    func needsRelocation(to frame: NSRect?) -> Bool {
        guard targetVisible, !isDismissing, let window, window.isVisible else { return false }
        if !window.isOnActiveSpace { return true }
        guard let target = frame ?? NSScreen.active?.frame else { return false }
        return window.screen?.frame != target
    }

    /// 不经过隐藏/暂停观察，直接把可见窗口挪到目标屏幕并重新滑入，避免数据重载闪烁
    func relocate(to frame: NSRect?) {
        guard let window else { return }
        let screenFrame = frame ?? NSScreen.active?.frame ?? .zero
        window.setFrame(
            NSRect(x: screenFrame.minX, y: screenFrame.minY, width: screenFrame.width, height: Const.defaultHeight),
            display: true
        )
        window.contentViewController?.view.layoutSubtreeIfNeeded()
        animateContent(visible: true, initiallyHidden: true) { [weak self] in
            self?.suppressSearchFocusRing(false)
        }
        window.makeKeyAndOrderFront(nil)
    }

    private func animateContent(
        visible: Bool,
        initiallyHidden: Bool = false,
        completion: @escaping @MainActor () -> Void
    ) {
        guard let view = window?.contentViewController?.view, let layer = view.layer else { return }
        suppressSearchFocusRing(true)
        slideAnimationGeneration += 1
        let generation = slideAnimationGeneration
        let key = "drawerSlide"
        let startY = initiallyHidden ? -view.bounds.height : (layer.presentation()?.transform.m42 ?? 0)

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.removeAnimation(forKey: key)
        CATransaction.setCompletionBlock { [weak self] in
            Task { @MainActor in
                guard let self, generation == self.slideAnimationGeneration else { return }
                if visible {
                    self.window?.contentViewController?.view.layer?.removeAnimation(forKey: key)
                }
                completion()
            }
        }

        // 仅动画呈现位置，避免文字因实际坐标移出窗口而被裁剪。
        let animation = CABasicAnimation(keyPath: "transform.translation.y")
        animation.fromValue = startY
        animation.toValue = visible ? 0 : -view.bounds.height
        animation.duration = visible ? Const.showDuration : Const.hideDuration
        animation.timingFunction = CAMediaTimingFunction(name: .easeOut)
        animation.fillMode = visible ? .both : .forwards
        animation.isRemovedOnCompletion = false
        layer.add(animation, forKey: key)
        CATransaction.commit()
    }

    private func suppressSearchFocusRing(_ suppressed: Bool) {
        (contentViewController as? ClipMainViewController)?
            .setSearchFocusRingSuppressed(suppressed)
    }
}

extension ClipMainWindowController: NSWindowDelegate {
    func windowDidResignKey(_: Notification) {
        HotKeyManager.shared.resetPressedKeys()
        guard !AppEnvironment.shared.suppressResignKey else { return }
        WindowManager.shared.dismiss()
    }
}
