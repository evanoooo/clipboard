//
//  SyncKeychainManager.swift
//  Clipboard
//
//  基于 macOS Keychain 的同步敏感凭据安全存储管理器
//

import Foundation
import Security

nonisolated final class SyncKeychainManager: Sendable {
    static let shared = SyncKeychainManager()

    private let serviceName = "com.crown.clipboard.sync"

    private enum AccountKey: String {
        case webdavPassword = "webdav_password"
        case syncPassphrase = "sync_passphrase"
    }

    private init() {}

    // MARK: - WebDAV 密码

    func saveWebDAVPassword(_ pass: String) throws {
        try save(string: pass, for: .webdavPassword)
    }

    func loadWebDAVPassword() -> String? {
        load(for: .webdavPassword)
    }

    func deleteWebDAVPassword() {
        delete(for: .webdavPassword)
    }

    // MARK: - 同步端到端加密密码 (Passphrase)

    func saveSyncPassphrase(_ phrase: String) throws {
        try save(string: phrase, for: .syncPassphrase)
    }

    func loadSyncPassphrase() -> String? {
        load(for: .syncPassphrase)
    }

    func deleteSyncPassphrase() {
        delete(for: .syncPassphrase)
    }

    // MARK: - 清空所有凭据

    func clearAllSyncCredentials() {
        deleteWebDAVPassword()
        deleteSyncPassphrase()
    }

    // MARK: - Keychain 底层接口

    private func save(string: String, for account: AccountKey) throws {
        guard let data = string.data(using: .utf8) else { return }

        // 先删除旧条目
        delete(for: account)

        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: serviceName,
            kSecAttrAccount: account.rawValue,
            kSecValueData: data,
            kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlock
        ]

        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status), userInfo: nil)
        }
    }

    private func load(for account: AccountKey) -> String? {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: serviceName,
            kSecAttrAccount: account.rawValue,
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne
        ]

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    private func delete(for account: AccountKey) {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: serviceName,
            kSecAttrAccount: account.rawValue
        ]
        SecItemDelete(query as CFDictionary)
    }
}
