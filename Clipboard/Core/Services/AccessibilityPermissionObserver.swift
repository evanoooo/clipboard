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
    }

    @objc private func handleAppDidBecomeActive() {
        checkPermission()
    }

    func startPollingIfUntrusted() {
        guard !isTrusted else { return }
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.checkPermission()
            }
        }
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
