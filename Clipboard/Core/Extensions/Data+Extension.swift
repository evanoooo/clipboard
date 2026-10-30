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
        return String(unsafeUninitializedCapacity: 64) { buffer in
            let hexDigits = ContiguousArray("0123456789abcdef".utf8)
            var offset = 0
            for byte in digest {
                buffer[offset] = hexDigits[Int(byte >> 4)]
                buffer[offset + 1] = hexDigits[Int(byte & 0x0F)]
                offset += 2
            }
            return 64
        }
    }
}
