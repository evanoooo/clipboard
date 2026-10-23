//
//  SyncCryptoTests.swift
//  Tests
//
//  Unit tests for End-to-End Encryption (PBKDF2 + AES-256-GCM) & Keychain Manager.
//

import CryptoKit
import Foundation

@MainActor
enum SyncCryptoTests {
    static func run(runner: TestRunner.Type) {
        print("\n--- Testing SyncCryptoEngine & E2EE Security ---")

        // 1. Salt Generation
        let salt1 = SyncCryptoEngine.generateSalt()
        let salt2 = SyncCryptoEngine.generateSalt()
        runner.assertEqual(salt1.count, 16, "Default salt length should be 16 bytes")
        runner.assertEqual(salt2.count, 16, "Default salt length should be 16 bytes")
        runner.assertTrue(salt1 != salt2, "Two generated salts should be distinct")

        // 2. Key Derivation (PBKDF2-HMAC-SHA256)
        let password = "MySecureSyncPassphrase#2026!"
        do {
            // Using small rounds in unit test for instant speed, e.g. 1000
            let keyA1 = try SyncCryptoEngine.deriveKey(passphrase: password, salt: salt1, rounds: 1000)
            let keyA2 = try SyncCryptoEngine.deriveKey(passphrase: password, salt: salt1, rounds: 1000)
            runner.assertTrue(keyA1 == keyA2, "Same password and salt must derive identical keys")

            let keyB = try SyncCryptoEngine.deriveKey(passphrase: password, salt: salt2, rounds: 1000)
            runner.assertTrue(keyA1 != keyB, "Different salts must derive different keys")

            let wrongPassKey = try SyncCryptoEngine.deriveKey(passphrase: "WrongPassword!", salt: salt1, rounds: 1000)
            runner.assertTrue(keyA1 != wrongPassKey, "Different passwords must derive different keys")
        } catch {
            runner.assertTrue(false, "Key derivation should succeed but failed: \(error)")
        }

        // 3. Empty Passphrase Defense
        do {
            _ = try SyncCryptoEngine.deriveKey(passphrase: "", salt: salt1)
            runner.assertTrue(false, "Empty passphrase must throw error")
        } catch let err as SyncCryptoError {
            runner.assertEqual(err, .invalidPassphrase, "Should throw invalidPassphrase error")
        } catch {
            runner.assertTrue(false, "Unexpected error thrown: \(error)")
        }

        // 4. AES-256-GCM Round-trip Encryption & Decryption
        do {
            let key = try SyncCryptoEngine.deriveKey(passphrase: password, salt: salt1, rounds: 1000)
            let rawString = "Hello, WebDAV End-to-End Encrypted World! 🔒🚀"
            let rawData = rawString.data(using: .utf8)!

            let encrypted1 = try SyncCryptoEngine.encrypt(data: rawData, using: key)
            let encrypted2 = try SyncCryptoEngine.encrypt(data: rawData, using: key)

            runner.assertTrue(encrypted1 != rawData, "Ciphertext must not match plaintext")
            runner.assertTrue(encrypted1 != encrypted2, "Two encryptions must have different nonces/ciphertexts")

            let decrypted = try SyncCryptoEngine.decrypt(data: encrypted1, using: key)
            let decryptedString = String(data: decrypted, encoding: .utf8)
            runner.assertEqual(decryptedString, rawString, "Decrypted string must match original")

            // 5. Decryption with Wrong Key must Fail
            let wrongKey = try SyncCryptoEngine.deriveKey(passphrase: "IncorrectPassword", salt: salt1, rounds: 1000)
            do {
                _ = try SyncCryptoEngine.decrypt(data: encrypted1, using: wrongKey)
                runner.assertTrue(false, "Decryption with wrong key must fail")
            } catch let err as SyncCryptoError {
                runner.assertEqual(err, .decryptionFailed, "Should throw decryptionFailed on wrong key")
            } catch {
                runner.assertTrue(false, "Unexpected error: \(error)")
            }

            // 6. Ciphertext Tampering Defense (AEAD Tag Verification)
            var tampered = encrypted1
            if tampered.count > 15 {
                tampered[tampered.count - 5] ^= 0xFF // Invert bits
                do {
                    _ = try SyncCryptoEngine.decrypt(data: tampered, using: key)
                    runner.assertTrue(false, "Tampered ciphertext must fail decryption")
                } catch let err as SyncCryptoError {
                    runner.assertEqual(err, .decryptionFailed, "AEAD tag verification must reject tampered data")
                } catch {
                    runner.assertTrue(false, "Unexpected error: \(error)")
                }
            }

            // 7. Checksum Accuracy
            let checksum1 = SyncCryptoEngine.checksum(for: rawData)
            let checksum2 = SyncCryptoEngine.checksum(for: rawData)
            let differentData = "Different string".data(using: .utf8)!
            let checksumDiff = SyncCryptoEngine.checksum(for: differentData)
            runner.assertEqual(checksum1, checksum2, "Same data must produce identical checksums")
            runner.assertTrue(checksum1 != checksumDiff, "Different data must produce different checksums")
            runner.assertEqual(checksum1.count, 16, "Checksum prefix should be 16 hex characters")

            print("✓ SyncCryptoEngine & E2EE Security tests passed!")
        } catch {
            print("❌ SyncCryptoTests failed with error: \(error)")
            exit(1)
        }
    }
}
