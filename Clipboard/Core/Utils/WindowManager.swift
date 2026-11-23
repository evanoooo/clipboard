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

    private var drawerController: ClipMainWindowController {
        ClipMainWindowController.shared
    }
    private var floatingController: ClipFloatingWindowController {
        ClipFloatingWindowController.shared
    }

    private var cancellables = Set<AnyCancellable>()

    private init() {
        UserDefaults.standard.publisher(for: \.displayMode)
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] newRaw in
                self?.handleDisplayModeChange(to: newRaw)
            }
            .store(in: &cancellables)

        NSWorkspace.shared.notificationCenter
            .publisher(for: NSWorkspace.activeSpaceDidChangeNotification)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.handleActiveSpaceDidChange()
            }
            .store(in: &cancellables)
    }

    private func handleActiveSpaceDidChange() {
        guard !AppEnvironment.shared.suppressResignKey else { return }
        switch displayMode {
        case .drawer:
            if ClipMainWindowController.isInstanceLoaded, drawerController.shouldDismissOnSpaceChange {
                dismiss(animated: false)
            }
        case .floating:
            if ClipFloatingWindowController.isInstanceLoaded, floatingController.shouldDismissOnSpaceChange {
                dismiss(animated: false)
            }
        }
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
            try? await Task.sleep(for: .seconds(5)) // 窗口关闭闲置 5 秒后自动回收富文本与翻页堆积缓存
            guard !Task.isCancelled, !self.isVisible else { return }
            PasteDataStore.main.trimExcessMemory()
        }
    }

    func toggleWindow(
        frame: NSRect? = nil,
        _ completionHandler: (@MainActor @Sendable () -> Void)? = nil
    ) {
        // 抽屉已在其他屏幕/Space 显示时迁移到当前屏幕，而不是先关闭（避免需要连按两次）
        if displayMode == .drawer, ClipMainWindowController.isInstanceLoaded,
           drawerController.needsRelocation(to: frame)
        {
            drawerController.relocate(to: frame)
            TimeManager.shared.start()
            idleTrimTask?.cancel()
            completionHandler?()
            return
        }

        switch displayMode {
        case .drawer:
            dismissFloatingIfNeeded()
            drawerController.toggleWindow(frame, completionHandler)
        case .floating:
            dismissDrawerIfNeeded()
            floatingController.toggleWindow(completionHandler)
        }
        if isVisible {
            TimeManager.shared.start()
            idleTrimTask?.cancel()
        } else {
            TimeManager.shared.stop()
            scheduleIdleMemoryTrim()
        }
    }

    /// 释放隐藏窗口中挂载的 visibleItems 的渲染产物与位图，降低闲置内存
    func releaseHiddenWindowPayloads() {
        if ClipMainWindowController.isInstanceLoaded, !ClipMainWindowController.shared.isVisible {
            ClipMainWindowController.shared.releaseVisibleCellPayloads()
        }
        if ClipFloatingWindowController.isInstanceLoaded, !ClipFloatingWindowController.shared.isVisible {
            ClipFloatingWindowController.shared.releaseVisibleCellPayloads()
        }
    }

    /// 幂等隐藏窗口，用于 Esc 退出、点击外部或操作完成关闭场景（避免 toggleWindow 造成竞态反向打开）
    func dismiss(
        animated: Bool = true,
        _ completionHandler: (@MainActor @Sendable () -> Void)? = nil
    ) {
        HotKeyManager.shared.resetPressedKeys()
        TimeManager.shared.stop()
        scheduleIdleMemoryTrim()
        switch displayMode {
        case .drawer:
            if ClipMainWindowController.isInstanceLoaded {
                drawerController.dismiss(animated: animated, completionHandler)
            } else {
                completionHandler?()
            }
        case .floating:
            if ClipFloatingWindowController.isInstanceLoaded {
                floatingController.dismiss(animated: animated, completionHandler)
            } else {
                completionHandler?()
            }
        }
    }

    var isVisible: Bool {
        (ClipMainWindowController.isInstanceLoaded && ClipMainWindowController.shared.isVisible)
            || (ClipFloatingWindowController.isInstanceLoaded && ClipFloatingWindowController.shared.isVisible)
    }

    var window: NSWindow? {
        switch displayMode {
        case .drawer:
            return ClipMainWindowController.isInstanceLoaded ? drawerController.window : nil
        case .floating:
            return ClipFloatingWindowController.isInstanceLoaded ? floatingController.window : nil
        }
    }

    func configureWindowSharing() {
        switch displayMode {
        case .drawer:
            if ClipMainWindowController.isInstanceLoaded {
                drawerController.configureWindowSharing()
            }
        case .floating:
            if ClipFloatingWindowController.isInstanceLoaded {
                floatingController.configureWindowSharing()
            }
        }
    }

    private func handleDisplayModeChange(to newRaw: Int) {
        switch DisplayMode(rawValue: newRaw) {
        case .drawer:
            dismissFloatingIfNeeded()
            if ClipFloatingWindowController.isInstanceLoaded {
                ClipFloatingWindowController.shared.pauseObserving()
            }
            if ClipMainWindowController.isInstanceLoaded {
                drawerController.resetState()
                drawerController.resumeObserving()
            }
        case .floating:
            dismissDrawerIfNeeded()
            if ClipMainWindowController.isInstanceLoaded {
                ClipMainWindowController.shared.pauseObserving()
            }
            if ClipFloatingWindowController.isInstanceLoaded {
                floatingController.resetState()
                floatingController.resumeObserving()
            }
        case nil:
            break
        }
    }

    private func dismissFloatingIfNeeded() {
        if ClipFloatingWindowController.isInstanceLoaded, floatingController.isVisible {
            floatingController.dismiss()
        }
    }

    private func dismissDrawerIfNeeded() {
        if ClipMainWindowController.isInstanceLoaded, drawerController.isVisible {
            drawerController.dismiss()
        }
    }
}
