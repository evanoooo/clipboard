//
//  PasteboardModel+RuntimeCache.swift
//  Clipboard
//
//  Non-persistent caches derived from immutable pasteboard payloads.
//

import AppKit

enum CodeDetectionState: Sendable, Equatable {
    case uncomputed
    case detected(CodeLanguage)
    case none
}

final class PasteboardModelRuntimeCache: @unchecked Sendable {
    var thumbnail: NSImage?
    var imageSize: CGSize?
    var backgroundColor: NSColor?
    var foregroundColor: NSColor?
    var richForegrounds: [NSColor] = []
    var previewForegrounds: [NSColor]?
    var filePaths: [String]?
    var hasBackgroundColor = false
    var needsBottomMask: Bool?
    var thumbnailLoadTask: Task<NSImage?, Never>?
    var linkMetadata: LinkPreviewMetadata?
    var codeDetectionState: CodeDetectionState = .uncomputed
    var plainTextAttributedString: NSAttributedString?
    var highlightedCode: NSAttributedString?
    var isLink: Bool?
    var isCSS: Bool?
    var plainText: String?

    func clear() {
        thumbnail = nil
        thumbnailLoadTask?.cancel()
        thumbnailLoadTask = nil
        linkMetadata = nil
        plainText = nil
        richForegrounds.removeAll()
        previewForegrounds = nil
        highlightedCode = nil
        plainTextAttributedString = nil
        isLink = nil
        isCSS = nil
    }
}

extension PasteboardModel {
    var cachedThumbnail: NSImage? {
        get { runtimeCache.thumbnail }
        set { runtimeCache.thumbnail = newValue }
    }

    var cachedImageSize: CGSize? {
        get {
            if let size = runtimeCache.imageSize {
                return size
            }
            if pasteboardType == .png || pasteboardType == .tiff {
                if length > 0 {
                    let w = CGFloat(length >> 32)
                    let h = CGFloat(length & 0xFFFF_FFFF)
                    if w > 0 && h > 0 {
                        let size = CGSize(width: w, height: h)
                        runtimeCache.imageSize = size
                        return size
                    }
                }
                // 仅当原始大图已经常驻内存时才从中解析，严禁为读取尺寸触发 loadData
                if hasLoadedData {
                    let size = Self.computeImageSize(from: data)
                    runtimeCache.imageSize = size
                    return size
                }
                // 历史遗留数据兜底：从已在内存中的 showData（缩略图）计算显示宽高
                if let sData = showData, !sData.isEmpty, let size = Self.computeImageSize(from: sData) {
                    runtimeCache.imageSize = size
                    return size
                }
            }
            return nil
        }
        set { runtimeCache.imageSize = newValue }
    }

    var cachedBackgroundColor: NSColor? {
        get { runtimeCache.backgroundColor }
        set { runtimeCache.backgroundColor = newValue }
    }

    var cachedForegroundColor: NSColor? {
        get { runtimeCache.foregroundColor }
        set { runtimeCache.foregroundColor = newValue }
    }

    var cachedRichForegrounds: [NSColor] {
        get { runtimeCache.richForegrounds }
        set { runtimeCache.richForegrounds = newValue }
    }

    var cachedPreviewForegrounds: [NSColor]? {
        get { runtimeCache.previewForegrounds }
        set { runtimeCache.previewForegrounds = newValue }
    }

    var cachedFilePaths: [String]? {
        get {
            if let paths = runtimeCache.filePaths {
                return paths
            }
            if pasteboardType == .fileURL {
                if let urlString = String(data: data, encoding: .utf8) {
                    let paths = urlString.components(separatedBy: "\n").filter { !$0.isEmpty }
                    runtimeCache.filePaths = paths
                    return paths
                }
            }
            return nil
        }
        set { runtimeCache.filePaths = newValue }
    }

    var cachedHasBackgroundColor: Bool {
        get { runtimeCache.hasBackgroundColor }
        set { runtimeCache.hasBackgroundColor = newValue }
    }

    var cachedNeedsBottomMask: Bool? {
        get { runtimeCache.needsBottomMask }
        set { runtimeCache.needsBottomMask = newValue }
    }

    var thumbnailLoadTask: Task<NSImage?, Never>? {
        get { runtimeCache.thumbnailLoadTask }
        set { runtimeCache.thumbnailLoadTask = newValue }
    }

    var cachedLinkMetadata: LinkPreviewMetadata? {
        get { runtimeCache.linkMetadata }
        set { runtimeCache.linkMetadata = newValue }
    }

    var cachedPlainTextAttributedString: NSAttributedString? {
        get { runtimeCache.plainTextAttributedString }
        set { runtimeCache.plainTextAttributedString = newValue }
    }

    var cachedHighlightedCode: NSAttributedString? {
        get { runtimeCache.highlightedCode }
        set { runtimeCache.highlightedCode = newValue }
    }

    /// 嗅探并缓存纯文本代码语言（如 Nginx、Swift、JSON 等）
    var detectedCodeLanguage: CodeLanguage? {
        switch runtimeCache.codeDetectionState {
        case .detected(let lang):
            return lang
        case .none:
            return nil
        case .uncomputed:
            guard type == .string, length >= 10 else {
                runtimeCache.codeDetectionState = .none
                return nil
            }
            // 优先在内存中判定：已载入完整数据则直接检测，避免磁盘 I/O
            if hasLoadedData {
                if let lang = CodeLanguageDetector.detect(data) {
                    runtimeCache.codeDetectionState = .detected(lang)
                    return lang
                } else {
                    runtimeCache.codeDetectionState = .none
                    return nil
                }
            }
            // 未载入 full data 时，优先用 attributeString 内存预览判定，杜绝列表渲染触发 50 次 SQLite 点查
            if let lang = CodeLanguageDetector.detect(attributeString.string) {
                runtimeCache.codeDetectionState = .detected(lang)
                return lang
            } else {
                runtimeCache.codeDetectionState = .none
                return nil
            }
        }
    }
}
