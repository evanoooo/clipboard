//
//  SettingViewModel.swift
//  Clipboard
//
//  Created by crown on 2026/4/18.
//

import AppKit
import Combine
import Foundation
import SwiftUI

@MainActor
@Observable final class SettingViewModel {
    var selectedPage: SettingPage = .general
    var hasAccessibilityPermission: Bool = AccessibilityPermissionObserver.shared.isTrusted

    @ObservationIgnored
    private var cancellables = Set<AnyCancellable>()

    init() {
        AccessibilityPermissionObserver.shared.permissionDidChange
            .receive(on: RunLoop.main)
            .sink { [weak self] trusted in
                self?.hasAccessibilityPermission = trusted
            }
            .store(in: &cancellables)
    }

    func navigateTo(_ page: SettingPage) {
        selectedPage = page
    }

    func refreshAccessibilityPermission() {
        hasAccessibilityPermission = AccessibilityPermissionObserver.shared.checkPermission()
    }

    func openAccessibilitySettings() {
        guard let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
        ) else { return }

        AccessibilityPermissionObserver.shared.startPollingIfUntrusted()
        NSWorkspace.shared.open(url)
    }
}
