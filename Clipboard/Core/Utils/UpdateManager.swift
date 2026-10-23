//
//  UpdateManager.swift
//  Clipboard
//
//  自动更新状态管理单例
//

import Foundation

@MainActor
@Observable
final class UpdateManager {
    static let shared = UpdateManager()

    private(set) var hasUpdate: Bool = false
    private(set) var availableVersion: String?

    private init() {}

    func setUpdateAvailable(version: String) {
        hasUpdate = true
        availableVersion = version
    }

    func clearUpdate() {
        hasUpdate = false
        availableVersion = nil
    }
}
