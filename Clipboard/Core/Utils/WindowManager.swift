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
        let wasVisible = isVisible
        switch displayMode {
        case .drawer:
            dismissFloatingIfNeeded()
            drawerController.toggleWindow(frame, completionHandler)
        case .floating:
            dismissDrawerIfNeeded()
            floatingController.toggleWindow(completionHandler)
        }
        if wasVisible {
            TimeManager.shared.stop()
            scheduleIdleMemoryTrim()
        } else {
            TimeManager.shared.start()
            idleTrimTask?.cancel()
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
    func dismiss(_ completionHandler: (@MainActor @Sendable () -> Void)? = nil) {
        HotKeyManager.shared.resetPressedKeys()
        TimeManager.shared.stop()
        scheduleIdleMemoryTrim()
        switch displayMode {
        case .drawer:
            if ClipMainWindowController.isInstanceLoaded {
                drawerController.dismiss(completionHandler)
            } else {
                completionHandler?()
            }
        case .floating:
            if ClipFloatingWindowController.isInstanceLoaded {
                floatingController.dismiss(completionHandler)
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
