//
//  UpdateManager.swift
//  Clipboard
//
//  自动更新状态管理单例
//

import Foundation

enum CheckUpdateStatus: Equatable {
    case idle
    case checking
    case upToDate
    case updateAvailable(version: String)
    case failed(message: String)
}

@MainActor
@Observable
final class UpdateManager {
    static let shared = UpdateManager()

    private(set) var hasUpdate: Bool = false
    private(set) var availableVersion: String?
    var status: CheckUpdateStatus = .idle

    private init() {}

    func setChecking() {
        status = .checking
    }

    func setUpToDate() {
        hasUpdate = false
        availableVersion = nil
        status = .upToDate
        resetStatusAfterDelay(seconds: 2.5)
    }

    func setUpdateAvailable(version: String) {
        hasUpdate = true
        availableVersion = version
        status = .updateAvailable(version: version)
    }

    func setFailed(message: String) {
        status = .failed(message: message)
        resetStatusAfterDelay(seconds: 3.0)
    }

    func clearUpdate() {
        hasUpdate = false
        availableVersion = nil
        status = .idle
    }

    private func resetStatusAfterDelay(seconds: Double) {
        Task {
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            if self.status == .upToDate || (caseFailed(self.status)) {
                self.status = .idle
            }
        }
    }

    private func caseFailed(_ s: CheckUpdateStatus) -> Bool {
        if case .failed = s { return true }
        return false
    }
}
