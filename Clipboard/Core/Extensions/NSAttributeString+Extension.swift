//
//  NSAttributeString+Extension.swift
//  Clipboard
//
//  Created by crown on 2025/9/13.
//

import AppKit

extension NSAttributedString {
    nonisolated convenience init?(with data: Data?, type: PasteboardType) {
        guard let data else { return nil }
        switch type {
        case .rtfd:
            if let attr = NSAttributedString(rtfd: data, documentAttributes: nil) {
                self.init(attributedString: attr)
            } else if let rtfFallback = NSAttributedString(rtf: data, documentAttributes: nil) {
                self.init(attributedString: rtfFallback)
            } else if let str = String(data: data, encoding: .utf8) {
                self.init(string: str)
            } else {
                return nil
            }
        case .rtf:
            if let attr = NSAttributedString(rtf: data, documentAttributes: nil) {
                self.init(attributedString: attr)
            } else if let str = String(data: data, encoding: .utf8) {
                self.init(string: str)
            } else {
                return nil
            }
        case .string:
            if let string = String(data: data, encoding: .utf8) {
                self.init(string: string)
            } else {
                return nil
            }
        default:
            return nil
        }
    }

    nonisolated func toData(with type: PasteboardType) -> Data? {
        switch type {
        case .rtf:
            rtf(from: NSMakeRange(0, length))
        case .rtfd:
            rtfd(from: NSMakeRange(0, length))
        case .string:
            string.data(using: .utf8)
        default:
            nil
        }
    }
}
