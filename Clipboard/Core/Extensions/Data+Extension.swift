//
//  Data+Extension.swift
//  Clipboard
//
//  Created by crown on 2025/9/13.
//

import CryptoKit
import Foundation

extension Data {
    nonisolated var sha256Hex: String {
        let digest = SHA256.hash(data: self)
        return digest.reduce(into: "") { result, byte in
            result += String(format: "%02hhx", byte)
        }
    }
}
