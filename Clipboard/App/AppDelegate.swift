//
//  AppDelegate.swift
//  clipboard
//
//  Created by crown on 2025/9/11.
//

import AppKit
import Combine
import QuartzCore
import Sparkle

class AppDelegate: NSObject {
    static var shared: AppDelegate?

    /// Sparkle 自动更新控制器
    lazy var updaterController: SPUStandardUpdaterController = .init(
        startingUpdater: true,
        updaterDelegate: self,
        userDriverDelegate: self
    )

    private var monitorToken: Any?
}

extension AppDelegate: NSApplicationDelegate {
    func applicationDidFinishLaunching(_: Notification) {
        Self.shared = self

        _ = updaterController

        setupStatusBar()

        setupMainMenu()

        applyAppearanceSettings()

        applyDockIconPolicy()

        Task {
            await initClipboardAsync()
        }
    }

    func applicationSupportsSecureRestorableState(_: NSApplication) -> Bool {
        true
    }

    func applicationWillTerminate(_: Notification) {
        if let token = monitorToken {
            NSEvent.removeMonitor(token)
            monitorToken = nil
        }
        StatusBarController.shared.cleanup()
        AppIconCache.shared.clearCache()
        HotKeyManager.shared.clear()
    }

    func applicationShouldHandleReopen(_: NSApplication, hasVisibleWindows _: Bool) -> Bool {
        WindowManager.shared.toggleWindow(frame: NSScreen.main?.frame)
        return true
    }

    private func applyDockIconPolicy() {
        let showDockIcon = PasteUserDefaults.showDockIcon
        NSApp.setActivationPolicy(showDockIcon ? .regular : .accessory)
    }

    private func applyAppearanceSettings() {
        let appearanceMode = AppearanceMode(
            rawValue: PasteUserDefaults.appearance
        ) ?? .system

        switch appearanceMode {
        case .system:
            NSApp.appearance = nil
        case .light:
            NSApp.appearance = NSAppearance(named: .aqua)
        case .dark:
            NSApp.appearance = NSAppearance(named: .darkAqua)
        }
    }

    private func setupStatusBar() {
        StatusBarController.shared.setup(
            onCheckUpdateClick: { [weak self] in
                self?.updaterController.checkForUpdates(nil)
            }
        )
    }

    private func setupMainMenu() {
        let mainMenu = NSMenu()
        let editMenuItem = NSMenuItem()
        mainMenu.addItem(editMenuItem)
        let editMenu = NSMenu(title: "Edit")
        editMenuItem.submenu = editMenu

        editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        let redoItem = editMenu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        redoItem.keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(NSMenuItem.separator())
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSResponder.selectAll(_:)), keyEquivalent: "a")

        NSApp.mainMenu = mainMenu
    }
}

extension AppDelegate {
    private func initClipboardAsync() async {
        guard await PasteDataStore.main.setup() else {
            presentDatabaseFailure()
            return
        }

        PasteBoard.main.startListening()

        initLocalEvent()

        HotKeyManager.shared.initialize()

        WelcomeWindowController.shared.showIfNeeded()

        syncLaunchAtLoginStatus()

        cleanupTempDirectories()
    }

    private func cleanupTempDirectories() {
        Task.detached(priority: .utility) {
            let tempDir = FileManager.default.temporaryDirectory
            try? FileManager.default.removeItem(at: tempDir.appending(path: "ClipboardDrag"))
            try? FileManager.default.removeItem(at: tempDir.appending(path: "ClipboardPaste"))
        }
    }

    /// 数据库不可用时明确告知用户，避免应用静默变成「不再记录剪贴板」。
    private func presentDatabaseFailure() {
        log.error("历史数据库初始化失败，本次运行不会记录剪贴板")

        AppEnvironment.shared.suppressResignKey = true
        defer { AppEnvironment.shared.suppressResignKey = false }

        let alert = NSAlert.appAlert()
        alert.alertStyle = .critical
        alert.messageText = String(localized: .dbUnavailableTitle)
        alert.informativeText = String(localized: .dbUnavailableMessage)
        alert.addButton(withTitle: String(localized: .dbUnavailableOpenFolder))
        alert.addButton(withTitle: String(localized: .commonConfirm))

        if alert.runModal() == .alertFirstButtonReturn {
            revealDatabaseDirectory()
        }
    }

    /// 目录可能因创建失败而不存在，此时退到其父目录，保证按钮总有反馈。
    private func revealDatabaseDirectory() {
        let directory = URL(filePath: PasteSQLManager.databasePath).deletingLastPathComponent()
        let target = FileManager.default.fileExists(atPath: directory.path)
            ? directory
            : directory.deletingLastPathComponent()
        NSWorkspace.shared.open(target)
    }

    private func syncLaunchAtLoginStatus() {
        let userDefaultsValue = PasteUserDefaults.onStart
        let actualValue = LaunchAtLoginHelper.shared.isEnabled
        if userDefaultsValue != actualValue {
            LaunchAtLoginHelper.shared.setEnabled(userDefaultsValue)
        }
    }
}

extension AppDelegate {
    private func initLocalEvent() {
        monitorToken = NSEvent.addLocalMonitorForEvents(matching: .keyDown) {
            event in
            if event.modifierFlags.contains(.command) {
                let modifiers = event.charactersIgnoringModifiers
                if modifiers == "," || modifiers == "，" {
                    SettingWindowController.shared.toggleWindow(page: .general)
                    return nil
                }
                if modifiers == "q" || modifiers == "Q" {
                    NSApplication.shared.terminate(nil)
                    return nil
                }
                if modifiers == "t" || modifiers == "T" {
                    EditWindowController.shared.openNewWindow()
                    return nil
                }
            }
            return event
        }
    }
}

// MARK: - Notification.Name

extension Notification.Name {
    static let menuBarIconVisibilityChanged = Notification.Name("menuBarIconVisibilityChanged")
}

// MARK: - SPUUpdaterDelegate

extension AppDelegate: SPUUpdaterDelegate, SPUStandardUserDriverDelegate {
    nonisolated func updaterWillCheckForUpdates(_: SPUUpdater) {
        Task { @MainActor in
            UpdateManager.shared.setChecking()
        }
    }

    nonisolated func updater(_: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        let version = item.displayVersionString
        Task { @MainActor in
            UpdateManager.shared.setUpdateAvailable(version: version)
        }
    }

    nonisolated func updaterDidNotFindUpdate(_: SPUUpdater) {
        Task { @MainActor in
            UpdateManager.shared.setUpToDate()
        }
    }

    nonisolated func updater(_: SPUUpdater, didAbortWithError error: Error) {
        Task { @MainActor in
            UpdateManager.shared.setFailed(message: error.localizedDescription)
        }
    }

    nonisolated func updater(
        _: SPUUpdater,
        userDidMake choice: SPUUserUpdateChoice,
        forUpdate _: SUAppcastItem,
        state _: SPUUserUpdateState
    ) {
        if choice == .skip {
            Task { @MainActor in
                UpdateManager.shared.clearUpdate()
            }
        }
    }

    var supportsGentleScheduledUpdateReminders: Bool {
        true
    }

    func standardUserDriverShouldHandleShowingScheduledUpdate(
        _: SUAppcastItem,
        andInImmediateFocus immediateFocus: Bool
    ) -> Bool {
        immediateFocus
    }

    func standardUserDriverWillHandleShowingUpdate(
        _ willHandle: Bool,
        forUpdate update: SUAppcastItem,
        state _: SPUUserUpdateState
    ) {
        guard !willHandle else { return }
        log.info("发现新版本：\(update.displayVersionString)")
        UpdateManager.shared.setUpdateAvailable(version: update.displayVersionString)
    }

    func standardUserDriverDidReceiveUserAttention(forUpdate _: SUAppcastItem) {
        updaterController.checkForUpdates(nil)
    }

    func standardUserDriverWillFinishUpdateSession() {
        UpdateManager.shared.clearUpdate()
    }
}
