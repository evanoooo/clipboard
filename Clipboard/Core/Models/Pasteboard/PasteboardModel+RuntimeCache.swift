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

struct PasteboardModelRuntimeCache {
    var thumbnail: NSImage?
    var imageSize: CGSize?
    var backgroundColor: NSColor?
    var foregroundColor: NSColor?
    var richForegrounds: [NSColor] = []
    var previewForegrounds: [NSColor]?
    var filePaths: [String]?
    var ocrRegions: [OCRTextRegion]?
    var ocrKeyword: String?
    var hasBackgroundColor = false
    var needsBottomMask: Bool?
    var thumbnailLoadTask: Task<NSImage?, Never>?
    var linkMetadata: LinkPreviewMetadata?
    var isMarkdown: Bool?
    var codeDetectionState: CodeDetectionState = .uncomputed
}

extension PasteboardModel {
    var cachedThumbnail: NSImage? {
        get { runtimeCache.thumbnail }
        set { runtimeCache.thumbnail = newValue }
    }

    var cachedImageSize: CGSize? {
        get { runtimeCache.imageSize }
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
        get { runtimeCache.filePaths }
        set { runtimeCache.filePaths = newValue }
    }

    var cachedOCRRegions: [OCRTextRegion]? {
        get { runtimeCache.ocrRegions }
        set { runtimeCache.ocrRegions = newValue }
    }

    var cachedOCRKeyword: String? {
        get { runtimeCache.ocrKeyword }
        set { runtimeCache.ocrKeyword = newValue }
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

    var cachedIsMarkdown: Bool? {
        get { runtimeCache.isMarkdown }
        set { runtimeCache.isMarkdown = newValue }
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
            // 用完整原文判定：`attributeString` 只有 300 字符预览，
            // docstring / 头部注释之后的 `def`、`import` 等信号会被截断。
            if let lang = CodeLanguageDetector.detect(data) {
                runtimeCache.codeDetectionState = .detected(lang)
                return lang
            } else {
                runtimeCache.codeDetectionState = .none
                return nil
            }
        }
    }
}
