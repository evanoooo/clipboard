//
//  AccessibilityPermissionObserver.swift
//  Clipboard
//
//  Created by crown on 2026/10/22.
//

import AppKit
import Combine
import Foundation

@MainActor
final class AccessibilityPermissionObserver {
    static let shared = AccessibilityPermissionObserver()

    private(set) var isTrusted: Bool = AXIsProcessTrusted()
    let permissionDidChange = PassthroughSubject<Bool, Never>()
    private var timer: Timer?

    private init() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleAppDidBecomeActive),
            name: NSApplication.didBecomeActiveNotification,
            object: nil
        )

        // 订阅系统辅助功能权限广播通知，当用户在「系统设置」授权时无需高频轮询即可秒级响应
        DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name("com.apple.accessibility.api"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            _ = MainActor.assumeIsolated {
                self?.checkPermission()
            }
        }
    }

    @objc private func handleAppDidBecomeActive() {
        checkPermission()
    }

    func startPollingIfUntrusted() {
        guard !isTrusted else { return }
        timer?.invalidate()
        // 降低未授权时的轮询频率（从 1.0s 优化为 5.0s，配合系统分布式通知与窗口激活即时检查，消除 CPU 永久 1Hz 唤醒空转）
        let timer = Timer(timeInterval: 5.0, repeats: true) { [weak self] _ in
            _ = MainActor.assumeIsolated {
                self?.checkPermission()
            }
        }
        timer.tolerance = 1.0
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stopPolling() {
        timer?.invalidate()
        timer = nil
    }

    @discardableResult
    func checkPermission() -> Bool {
        let current = AXIsProcessTrusted()
        if current != isTrusted {
            isTrusted = current
            permissionDidChange.send(current)
            if current {
                stopPolling()
                PasteBoard.main.refreshPermissions()
            }
        }
        return current
    }
}
