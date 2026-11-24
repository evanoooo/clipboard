//
//  PasteboardModel+Tool.swift
//  Clipboard
//
//  Created by crown on 2026/3/11.
//

import AppKit

extension PasteboardModel {
    nonisolated static func generateUniqueId(
        for type: PasteboardType,
        data: Data
    ) -> String {
        switch type {
        case .png, .tiff, .rtf, .rtfd:
            return "\(type.rawValue):\(data.sha256Hex)"
        default:
            return data.sha256Hex
        }
    }

    /// 提取文件条目的全部文件路径，用于支持多文件拖拽至 Finder 等目标。
    var filePathsForDragging: [String] {
        guard pasteboardType.isFile(),
              let raw = String(data: loadRawData(cache: false), encoding: .utf8) else {
            return []
        }
        return raw
            .components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    // MARK: - 计算图片尺寸

    nonisolated static func computeImageSize(from data: Data) -> CGSize? {
        let options = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, options) else {
            return nil
        }
        return computeImageSize(from: source, options: options)
    }

    nonisolated static func computeImageSize(from url: URL) -> CGSize? {
        let options = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithURL(url as CFURL, options) else {
            return nil
        }
        return computeImageSize(from: source, options: options)
    }

    nonisolated static func packImageLength(for data: Data) -> Int {
        guard let size = computeImageSize(from: data) else { return 0 }
        let width = Int(size.width)
        let height = Int(size.height)
        guard width > 0, height > 0 else { return 0 }
        return (width << 32) | (height & 0xFFFF_FFFF)
    }

    nonisolated private static func computeImageSize(from source: CGImageSource, options: CFDictionary) -> CGSize? {
        guard
            let properties = CGImageSourceCopyPropertiesAtIndex(
                source,
                0,
                options
            ) as? [CFString: Any]
        else {
            return nil
        }

        let width: CGFloat
        let height: CGFloat

        if let w = properties[kCGImagePropertyPixelWidth] as? Int {
            width = CGFloat(w)
        } else if let w = properties[kCGImagePropertyPixelWidth] as? CGFloat {
            width = w
        } else {
            return nil
        }

        if let h = properties[kCGImagePropertyPixelHeight] as? Int {
            height = CGFloat(h)
        } else if let h = properties[kCGImagePropertyPixelHeight] as? CGFloat {
            height = h
        } else {
            return nil
        }

        let dpi = properties[kCGImagePropertyDPIWidth] as? CGFloat ?? 72.0
        let scale = dpi / 72.0

        return CGSize(width: width / scale, height: height / scale)
    }
}
