//
//  SyncCryptoEngine.swift
//  Clipboard
//
//  端到端加密引擎：PBKDF2-HMAC-SHA256 密钥派生 + AES-256-GCM 认证加解密 (AEAD)
//

import CommonCrypto
import CryptoKit
import Foundation

enum SyncCryptoError: LocalizedError, Equatable {
    case keyDerivationFailed
    case encryptionFailed
    case decryptionFailed
    case invalidPassphrase
    case dataCorrupted

    var errorDescription: String? {
        switch self {
        case .keyDerivationFailed:
            return "密钥派生失败，请检查同步密码与 Salt"
        case .encryptionFailed:
            return "数据加密失败"
        case .decryptionFailed:
            return "数据解密失败：同步密码错误或数据已损坏"
        case .invalidPassphrase:
            return "同步密码无效（密码不能为空）"
        case .dataCorrupted:
            return "密文数据结构损坏或被篡改"
        }
    }
}

nonisolated final class SyncCryptoEngine: Sendable {
    /// 默认 PBKDF2 迭代轮数（平衡安全性与移动/Mac 能耗）
    static let defaultPBKDF2Rounds: UInt32 = 100_000
    /// 默认 Salt 字节长度
    static let defaultSaltLength: Int = 16

    /// 生成安全的加密强伪随机 Salt
    static func generateSalt(length: Int = defaultSaltLength) -> Data {
        var salt = Data(count: length)
        let result = salt.withUnsafeMutableBytes {
            SecRandomCopyBytes(kSecRandomDefault, length, $0.baseAddress!)
        }
        if result != errSecSuccess {
            // 降级为系统随机数
            return (0..<length).map { _ in UInt8.random(in: 0...255) }.reduce(into: Data()) { $0.append($1) }
        }
        return salt
    }

    /// 基于用户输入的同步密码和 Salt，通过 PBKDF2-HMAC-SHA256 派生 256 位对称密钥
    static func deriveKey(
        passphrase: String,
        salt: Data,
        rounds: UInt32 = defaultPBKDF2Rounds
    ) throws -> SymmetricKey {
        guard !passphrase.isEmpty else {
            throw SyncCryptoError.invalidPassphrase
        }

        var derivedKeyBytes = [UInt8](repeating: 0, count: 32) // 256 bits
        let status = CCKeyDerivationPBKDF(
            CCPBKDFAlgorithm(kCCPBKDF2),
            passphrase,
            passphrase.utf8.count,
            (salt as NSData).bytes.bindMemory(to: UInt8.self, capacity: salt.count),
            salt.count,
            CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256),
            rounds,
            &derivedKeyBytes,
            derivedKeyBytes.count
        )

        guard status == kCCSuccess else {
            throw SyncCryptoError.keyDerivationFailed
        }

        return SymmetricKey(data: Data(derivedKeyBytes))
    }

    /// 使用 AES-256-GCM 加密数据（AEAD 保证保密性 + 完整性校验）
    /// 输出格式：12 字节 Nonce + 密文 + 16 字节 GCM Tag
    static func encrypt(data: Data, using key: SymmetricKey) throws -> Data {
        do {
            let sealedBox = try AES.GCM.seal(data, using: key)
            guard let combined = sealedBox.combined else {
                throw SyncCryptoError.encryptionFailed
            }
            return combined
        } catch {
            throw SyncCryptoError.encryptionFailed
        }
    }

    /// 使用 AES-256-GCM 解密数据，若密码错误或密文被篡改，自动抛出 decryptionFailed
    static func decrypt(data: Data, using key: SymmetricKey) throws -> Data {
        do {
            let sealedBox = try AES.GCM.SealedBox(combined: data)
            return try AES.GCM.open(sealedBox, using: key)
        } catch {
            throw SyncCryptoError.decryptionFailed
        }
    }

    /// 计算数据的 SHA-256 哈希值前 16 位 Hex（用于轻量索引比对数据是否变动）
    static func checksum(for data: Data) -> String {
        let digest = SHA256.hash(data: data)
        return digest.prefix(8).map { String(format: "%02x", $0) }.joined()
    }
}
