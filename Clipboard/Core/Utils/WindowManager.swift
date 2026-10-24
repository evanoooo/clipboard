//
//  WindowManager.swift
//  Clipboard
//
//  Created by crown on 2025/1/14.
//

import AppKit
import Combine
import Foundation

@MainActor
final class WindowManager {
    static let shared = WindowManager()

    private let drawerController = ClipMainWindowController.shared
    private let floatingController = ClipFloatingWindowController.shared

    private var cancellables = Set<AnyCancellable>()

    private init() {
        UserDefaults.standard.publisher(for: \.displayMode)
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] newRaw in
                self?.handleDisplayModeChange(to: newRaw)
            }
            .store(in: &cancellables)
    }

    // MARK: - 当前显示模式

    var displayMode: DisplayMode {
        let rawValue = UserDefaults.standard.integer(forKey: PrefKey.displayMode.rawValue)
        return DisplayMode(rawValue: rawValue) ?? .drawer
    }

    private var idleTrimTask: Task<Void, Never>?

    private func scheduleIdleMemoryTrim() {
        idleTrimTask?.cancel()
        idleTrimTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(300)) // 5 分钟闲置
            guard !Task.isCancelled, !self.isVisible else { return }
            PasteDataStore.main.trimExcessMemory()
        }
    }

    func toggleWindow(
        frame: NSRect? = nil,
        _ completionHandler: (@MainActor @Sendable () -> Void)? = nil
    ) {
        idleTrimTask?.cancel()
        switch displayMode {
        case .drawer:
            dismissFloatingIfNeeded()
            drawerController.toggleWindow(frame, completionHandler)
        case .floating:
            dismissDrawerIfNeeded()
            floatingController.toggleWindow(completionHandler)
        }
    }

    /// 幂等隐藏窗口，用于 Esc 退出、点击外部或操作完成关闭场景（避免 toggleWindow 造成竞态反向打开）
    func dismiss(_ completionHandler: (@MainActor @Sendable () -> Void)? = nil) {
        scheduleIdleMemoryTrim()
        switch displayMode {
        case .drawer:
            drawerController.dismiss(completionHandler)
        case .floating:
            floatingController.dismiss(completionHandler)
        }
    }

    var isVisible: Bool {
        drawerController.isVisible || floatingController.isVisible
    }

    var window: NSWindow? {
        switch displayMode {
        case .drawer: drawerController.window
        case .floating: floatingController.window
        }
    }

    func configureWindowSharing() {
        switch displayMode {
        case .drawer: drawerController.configureWindowSharing()
        case .floating: floatingController.configureWindowSharing()
        }
    }

    private func handleDisplayModeChange(to newRaw: Int) {
        switch DisplayMode(rawValue: newRaw) {
        case .drawer:
            drawerController.resetState()
        case .floating:
            floatingController.resetState()
        case nil:
            break
        }
    }

    private func dismissFloatingIfNeeded() {
        if floatingController.isVisible {
            floatingController.dismiss()
        }
    }

    private func dismissDrawerIfNeeded() {
        if drawerController.isVisible {
            drawerController.dismiss()
        }
    }
}
