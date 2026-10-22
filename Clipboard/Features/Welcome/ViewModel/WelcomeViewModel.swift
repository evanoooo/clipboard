//
//  WelcomeViewModel.swift
//  Clipboard
//

import AppKit
import ApplicationServices
import Combine
import Observation

@MainActor
@Observable
final class WelcomeViewModel {
    private(set) var currentPage: WelcomePage = .introduction
    private(set) var isMovingForward = true
    var hasAccessibilityPermission: Bool = AccessibilityPermissionObserver.shared.isTrusted

    @ObservationIgnored
    private var cancellables = Set<AnyCancellable>()

    init(currentPage: WelcomePage = .introduction) {
        self.currentPage = currentPage
        AccessibilityPermissionObserver.shared.permissionDidChange
            .receive(on: RunLoop.main)
            .sink { [weak self] trusted in
                self?.hasAccessibilityPermission = trusted
            }
            .store(in: &cancellables)
    }

    func select(_ page: WelcomePage) {
        isMovingForward = page.rawValue >= currentPage.rawValue
        currentPage = page
    }

    func goToNextPage() {
        guard let nextPage = currentPage.next else { return }
        select(nextPage)
    }

    func goToPreviousPage() {
        guard let previousPage = currentPage.previous else { return }
        select(previousPage)
    }

    func refreshAccessibilityPermission() {
        hasAccessibilityPermission = AccessibilityPermissionObserver.shared.checkPermission()
    }

    func openAccessibilitySettings() {
        guard let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
        ) else {
            return
        }
        AccessibilityPermissionObserver.shared.startPollingIfUntrusted()
        NSWorkspace.shared.open(url)
    }
}
