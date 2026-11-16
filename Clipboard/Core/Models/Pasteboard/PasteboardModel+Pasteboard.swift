//
//  PasteboardModel+Pasteboard.swift
//  Clipboard
//
//  Created by crown on 2026/3/11.
//

import AppKit
import ImageIO

extension PasteboardModel {
    convenience init?(
        with pasteboard: NSPasteboard,
        sourceApp: NSRunningApplication? = nil,
        preloadedData: Data? = nil
    ) {
        guard let items = pasteboard.pasteboardItems, let item = items.first
        else { return nil }

        let type: PasteboardType
        var extractedPaths: [String]?
        if let paths = Self.extractFilePaths(from: pasteboard, item: item),
           !paths.isEmpty {
            type = .fileURL
            extractedPaths = paths
        } else if let matched = item.availableType(from: PasteboardType.supportTypes) {
            type = matched
        } else {
            return nil
        }

        var content: Data?
        var searchText = ""
        var length = 0

        if type.isFile() {
            guard let paths = extractedPaths,
                  !paths.isEmpty
            else { return nil }

            searchText = Self.normalizeSearchText(paths.joined(separator: " "))

            let filePathsString = paths.joined(separator: "\n")
            content = filePathsString.data(using: .utf8) ?? Data()
        } else if type == .string, let preloadedData {
            content = preloadedData
        } else {
            content = item.data(forType: type)
        }
        guard content != nil else { return nil }

        var showData: Data?
        var extractedTextString: String?
        if type.isText() {
            guard let text = Self.prepareText(content, type: type) else { return nil }
            length = text.source.length
            showData = text.showData
            let rawString = text.source.string
            extractedTextString = rawString
            searchText = Self.normalizeSearchText(rawString)
        } else if type.isImage(), let content {
            showData = Self.generateImageThumbnailData(from: content, maxPixelSize: 300)
            if let size = Self.computeImageSize(from: content) {
                let w = Int(size.width)
                let h = Int(size.height)
                if w > 0 && h > 0 {
                    length = (w << 32) | (h & 0xFFFF_FFFF)
                }
            }
        }

        let calculatedTag = Self.calculateTag(type: type, content: content ?? Data(), extractedText: extractedTextString)
        let precomputedUniqueId: String? = if let content, (type == .rtf || type == .rtfd) {
            "\(type.rawValue):\(content.sha256Hex)"
        } else {
            nil
        }

        let app = sourceApp ?? NSWorkspace.shared.frontmostApplication

        self.init(
            pasteboardType: type,
            data: content ?? Data(),
            showData: showData ?? Data(),
            timestamp: Int64(Date().timeIntervalSince1970),
            appPath: app?.bundleURL?.path ?? "",
            appName: app?.localizedName ?? "",
            searchText: searchText,
            length: length,
            group: -1,
            tag: calculatedTag,
            uniqueId: precomputedUniqueId,
            sourceBundleID: app?.bundleIdentifier
        )
    }

    private static func prepareText(
        _ content: Data?, type: PasteboardType
    ) -> (source: NSAttributedString, showData: Data?)? {
        guard let content, !content.isEmpty else { return nil }
        // 针对过大富文本（>256KB），避免在入库时全量反序列化 RTF 导致主线程卡顿，也不把原始 RTF 控制字当作正文
        if (type == .rtf || type == .rtfd) && content.count > 262_144 {
            let extracted = extractPlainTextFromLargeRichText(content, type: type)
            guard !extracted.allSatisfy(\.isWhitespace) else { return nil }
            let preview = String(extracted.prefix(300))
            let attr = NSAttributedString(string: extracted)
            return (attr, Data(preview.utf8))
        }
        let text = NSAttributedString(with: content, type: type) ?? NSAttributedString()
        guard !text.string.allSatisfy(\.isWhitespace) else { return nil }
        let preview = text.length > 300
            ? text.attributedSubstring(from: NSRange(location: 0, length: 300)) : text
        var previewData: Data?
        if type == .rtfd {
            // 剥离内嵌附件后转为轻量 RTF 存入 showData，避免数十 MB 图片附件常驻内存
            let mutable = NSMutableAttributedString(attributedString: preview)
            mutable.removeAttribute(.attachment, range: NSRange(location: 0, length: mutable.length))
            previewData = mutable.toData(with: .rtf)
        } else {
            previewData = preview.toData(with: type)
        }
        if let data = previewData, data.count > 16_384 {
            previewData = Data(preview.string.utf8)
        }
        return (text, previewData)
    }

    /// 对超大 RTF/RTFD 进行轻量纯文本提取，避免全量反序列化富文本或将原始 RTF 控制字当作正文。
    private static func extractPlainTextFromLargeRichText(_ data: Data, type: PasteboardType) -> String {
        let rtfData: Data
        if type == .rtfd {
            guard let wrapper = FileWrapper(serializedRepresentation: data),
                  let txtRTF = wrapper.fileWrappers?["TXT.rtf"]?.regularFileContents else {
                return ""
            }
            if txtRTF.count <= 262_144,
               let attr = NSAttributedString(with: txtRTF, type: .rtf) {
                return attr.string
            }
            rtfData = txtRTF
        } else {
            rtfData = data
        }

        // 限制扫描前 512KB 以确保入库零卡顿
        let slice = rtfData.prefix(524_288)
        guard let raw = String(data: slice, encoding: .ascii) ?? String(data: slice, encoding: .utf8) else {
            return ""
        }
        return stripRTFControlWords(raw)
    }

    private static func stripRTFControlWords(_ rtf: String) -> String {
        let skippedDestinations: Set<String> = [
            "fonttbl", "colortbl", "stylesheet", "info", "pict", "object",
            "fldinst", "header", "footer", "headerl", "headerr", "headerf",
            "footerl", "footerr", "footerf", "listtable", "listoverridetable"
        ]
        var result = ""
        result.reserveCapacity(min(rtf.count / 4, 32_768))

        let chars = Array(rtf.unicodeScalars)
        let count = chars.count
        var i = 0
        var depth = 0
        var skipDepth: Int?

        while i < count {
            let ch = chars[i]
            if ch == "{" {
                depth += 1
                if skipDepth == nil, i + 2 < count, chars[i + 1] == "\\", chars[i + 2] == "*" {
                    skipDepth = depth
                }
                i += 1
                continue
            }
            if ch == "}" {
                if let sd = skipDepth, depth <= sd {
                    skipDepth = nil
                }
                depth = max(0, depth - 1)
                i += 1
                continue
            }
            if skipDepth != nil {
                i += 1
                continue
            }
            if ch == "\\" {
                i += 1
                guard i < count else { break }
                let next = chars[i]
                if next == "\\" || next == "{" || next == "}" {
                    result.unicodeScalars.append(next)
                    i += 1
                } else if next == "'" {
                    // \'hh 十六进制转义：跳过两字符
                    i = min(count, i + 3)
                } else if next == "~" {
                    result.append(" ")
                    i += 1
                } else if next == "\n" || next == "\r" {
                    result.append("\n")
                    i += 1
                } else if CharacterSet.letters.contains(next) {
                    let wordStart = i
                    while i < count, CharacterSet.letters.contains(chars[i]) {
                        i += 1
                    }
                    let word = String(String.UnicodeScalarView(chars[wordStart..<i]))
                    // 跳过可选数字参数
                    if i < count, (chars[i] == "-" || CharacterSet.decimalDigits.contains(chars[i])) {
                        i += 1
                        while i < count, CharacterSet.decimalDigits.contains(chars[i]) {
                            i += 1
                        }
                    }
                    if i < count, chars[i] == " " {
                        i += 1
                    }
                    if skippedDestinations.contains(word) {
                        skipDepth = depth
                    } else if word == "par" || word == "line" {
                        result.append("\n")
                    } else if word == "tab" {
                        result.append("\t")
                    }
                } else {
                    i += 1
                }
                continue
            }
            if ch == "\r" || ch == "\n" {
                i += 1
                continue
            }
            result.unicodeScalars.append(ch)
            i += 1
        }
        return result
    }

    // MARK: - 缩略图生成

    static func generateImageThumbnailData(from data: Data, maxPixelSize: CGFloat = 300) -> Data? {
        ImageDownsampler.generateThumbnailData(from: data, maxPixelSize: maxPixelSize)
    }

    // MARK: - 从剪贴板提取文件路径

    static func extractFilePaths(
        from pasteboard: NSPasteboard,
        item: NSPasteboardItem
    ) -> [String]? {
        if let urls = pasteboard.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        ) as? [URL], !urls.isEmpty {
            return urls.map(\.path)
        }

        let appleURLType = NSPasteboard.PasteboardType("Apple URL pasteboard type")
        if let paths = parseFileURLStrings(from: item, type: appleURLType) {
            return paths
        }

        let gnomeType = NSPasteboard.PasteboardType("x-special/gnome-copied-files")
        if let str = item.string(forType: gnomeType) {
            let lines = str.components(separatedBy: "\n")
                .dropFirst()
            let paths = lines.compactMap { extractPathFromFileURL($0) }
            if !paths.isEmpty {
                return paths
            }
        }

        let skipTypes: Set<String> = [
            NSPasteboard.PasteboardType.string.rawValue,
            NSPasteboard.PasteboardType.rtf.rawValue,
            NSPasteboard.PasteboardType.rtfd.rawValue,
            "public.utf8-plain-text",
            "public.html"
        ]
        let hasTextContent = item.types.contains { skipTypes.contains($0.rawValue) }
        guard !hasTextContent else { return nil }
        for itemType in item.types where !skipTypes.contains(itemType.rawValue) {
            if let str = item.string(forType: itemType) ?? (item.propertyList(forType: itemType) as? String) {
                let paths = str.components(separatedBy: "\n")
                    .compactMap { extractPathFromFileURL($0) }
                if !paths.isEmpty {
                    return paths
                }
            }
        }

        return nil
    }

    private static func parseFileURLStrings(
        from item: NSPasteboardItem,
        type: NSPasteboard.PasteboardType
    ) -> [String]? {
        guard let str = item.string(forType: type) else { return nil }
        let paths = str.components(separatedBy: "\n")
            .compactMap { extractPathFromFileURL($0) }
        return paths.isEmpty ? nil : paths
    }

    private static func extractPathFromFileURL(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("file:") else { return nil }

        if let url = URL(string: trimmed), url.isFileURL {
            return url.path
        }

        let stripped = trimmed.replacing("file:", with: "")
        let path = stripped.hasPrefix("//")
            ? String(stripped.dropFirst(2))
            : stripped
        return path.hasPrefix("/") ? path : nil
    }

    nonisolated static func calculateTextTag(_ text: String) -> String {
        if text.isCSSHexColor { return "color" }
        if text.asCompleteURL() != nil { return "link" }
        return "string"
    }

    static func calculateTag(type: PasteboardType, content: Data, extractedText: String? = nil) -> String {
        switch type {
        case .rtf, .rtfd:
            let str = extractedText ?? NSAttributedString(with: content, type: type)?.string
            if let str {
                if str.isCSSHexColor {
                    return "color"
                }
                if str.asCompleteURL() != nil {
                    return "link"
                }
            }
            return "rich"
        case .string:
            let str = extractedText ?? String(data: content, encoding: .utf8)
            guard let str else {
                return "string"
            }
            return calculateTextTag(str)
        case .png, .tiff:
            return "image"
        case .fileURL:
            return "file"
        default:
            return ""
        }
    }
}
