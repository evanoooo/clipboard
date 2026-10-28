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
        return digest.map { byte in
            let hex = String(byte, radix: 16)
            return hex.count == 1 ? "0" + hex : hex
        }.joined()
    }
}
