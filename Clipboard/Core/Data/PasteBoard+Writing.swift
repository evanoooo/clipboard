//
//  PasteBoard+Writing.swift
//  Clipboard
//
//  将历史条目写回系统剪贴板（单条/多选合并、富文本去尾换行、外置图片零拷贝临时文件）
//

import AppKit
import Foundation

extension PasteBoard {
    // MARK: - 写入剪贴板接口

    /// 将多个项目合并写入系统剪贴板
    /// 文本类型会用换行符拼接，文件类型会合并 URL，其他类型只写入第一个
    func pasteMultipleData(
        _ items: [PasteboardModel],
        isAttribute: Bool = true,
        showTip: Bool = false,
        copy: Bool = false
    ) {
        guard !items.isEmpty else { return }

        PasteDataStore.main.updateItemsTimestamp(items: items)

        NSPasteboard.general.clearContents()

        let success = writeMultipleToPasteboard(items, isAttribute: isAttribute)
        ownWriteChangeCount = pasteboard.changeCount
        changeCount = pasteboard.changeCount
        guard success else { return }

        PasteDataStore.main.moveItemsToFirst(items)
        SoundManager.shared.play(.paste)
        if showTip {
            Task { @MainActor in
                copy ? HUDManager.shared.showCopySucceeded() : HUDManager.shared.showPasteSucceeded()
            }
        }
    }

    /// 将多个项目合并写入剪贴板
    private func writeMultipleToPasteboard(
        _ items: [PasteboardModel],
        isAttribute: Bool
    ) -> Bool {
        let shouldPasteAsPlainText =
            !isAttribute || PasteUserDefaults.pasteOnlyText

        let textItems = items.filter { $0.pasteboardType.isText() }
        let fileItems = items.filter { $0.type == .file }
        let imageItems = items.filter { $0.pasteboardType.isImage() }

        // 文件类型
        if !fileItems.isEmpty {
            if !isAttribute {
                let paths = fileItems.flatMap { $0.cachedFilePaths ?? [] }
                guard !paths.isEmpty else { return false }
                NSPasteboard.general.setString(paths.joined(separator: "\n"), forType: .string)
                return true
            }
            return writeMultipleFileURLs(fileItems)
        }

        // 图片类型
        if !imageItems.isEmpty {
            if !isAttribute {
                let text = imageItems.filter(\.hasValidSearchText).map(\.searchText).joined(separator: "\n")
                guard !text.isEmpty else { return false }
                NSPasteboard.general.setString(text, forType: .string)
                return true
            }
            return writeMultipleImages(imageItems)
        }

        // 文本类型合并
        if !textItems.isEmpty {
            if shouldPasteAsPlainText {
                return writeMultiplePlainText(textItems)
            } else {
                return writeMultipleRichText(textItems)
            }
        }

        return false
    }

    /// 合并多个纯文本
    private func writeMultiplePlainText(_ items: [PasteboardModel]) -> Bool {
        let texts = items.compactMap { item -> String? in
            var text = item.plainText
            if PasteUserDefaults.removeTailingNewline {
                text = text.trimmingTrailingNewlines()
            }
            return text.isEmpty ? nil : text
        }
        guard !texts.isEmpty else { return false }

        let combined = texts.joined(separator: "\n")
        NSPasteboard.general.setString(combined, forType: .string)
        return true
    }

    /// 合并多个富文本
    private func writeMultipleRichText(_ items: [PasteboardModel]) -> Bool {
        let combined = NSMutableAttributedString()
        let newline = NSAttributedString(string: "\n")

        for (index, item) in items.enumerated() {
            if let attr = NSAttributedString(
                with: item.loadRawData(cache: false),
                type: item.pasteboardType
            ) {
                let mutable = NSMutableAttributedString(attributedString: attr)
                if PasteUserDefaults.removeTailingNewline {
                    mutable.trimTrailingNewlines()
                }
                combined.append(mutable)
                if index < items.count - 1 {
                    combined.append(newline)
                }
            } else {
                var text = item.plainText
                if PasteUserDefaults.removeTailingNewline {
                    text = text.trimmingTrailingNewlines()
                }
                combined.append(NSAttributedString(string: text))
                if index < items.count - 1 {
                    combined.append(newline)
                }
            }
        }

        guard combined.length > 0 else { return false }

        let rtfType = items.first?.pasteboardType ?? .rtf
        if let data = combined.toData(with: rtfType) {
            NSPasteboard.general.setData(data, forType: rtfType)
        } else {
            NSPasteboard.general.setString(combined.string, forType: .string)
        }
        return true
    }

    /// 合并多个文件 URL
    private func writeMultipleFileURLs(_ items: [PasteboardModel]) -> Bool {
        let fileManager = FileManager.default
        var allURLs: [URL] = []

        for item in items {
            guard let filePaths = String(data: item.loadRawData(cache: false), encoding: .utf8)
            else {
                continue
            }
            let urls =
                filePaths
                    .components(separatedBy: "\n")
                    .lazy
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty && fileManager.fileExists(atPath: $0) }
                    .map { URL(fileURLWithPath: $0) }
            allURLs.append(contentsOf: urls)
        }

        guard !allURLs.isEmpty else { return false }
        pasteboard.writeObjects(allURLs as [NSPasteboardWriting])
        return true
    }

    /// 多张图片写入剪贴板：先写为临时文件，再以文件 URL 方式写入（确保目标应用能接收全部图片）
    private func writeMultipleImages(_ items: [PasteboardModel]) -> Bool {
        let sessionDir = FileManager.default.temporaryDirectory
            .appending(path: "ClipboardPaste")
            .appending(path: UUID().uuidString)

        try? FileManager.default.createDirectory(
            at: sessionDir,
            withIntermediateDirectories: true
        )

        var fileURLs: [URL] = []
        let fileManager = FileManager.default
        for (index, item) in items.enumerated() {
            let ext = item.pasteboardType == .png ? "png" : "tiff"
            let fileName = "image_\(index + 1).\(ext)"
            let fileURL = sessionDir.appending(path: fileName)
            do {
                if let mediaURL = item.mediaFileURL {
                    try fileManager.copyItem(at: mediaURL, to: fileURL)
                } else {
                    try item.loadRawData(cache: false).write(to: fileURL)
                }
                fileURLs.append(fileURL)
            } catch {
                log.error("写入临时图片文件失败: \(error)")
            }
        }

        guard !fileURLs.isEmpty else { return false }
        pasteboard.writeObjects(fileURLs as [NSPasteboardWriting])

        // 粘贴完成后延迟清理本次会话临时文件，给目标应用足够时间读取，互不干扰
        let cleanupDir = sessionDir
        Task.detached {
            try? await Task.sleep(for: .seconds(15))
            try? FileManager.default.removeItem(at: cleanupDir)
        }

        return true
    }

    /// 将数据写入系统剪贴板
    /// - Returns: 是否成功写入
    private func writeToPasteboard(_ data: PasteboardModel, isAttribute: Bool)
        -> Bool {
        let shouldPasteAsPlainText =
            !isAttribute || PasteUserDefaults.pasteOnlyText

        if data.pasteboardType.isText(), shouldPasteAsPlainText {
            writePlainText(data)
            return true
        }
        if data.type == .file {
            return writeFileURLs(data)
        }
        writeRawData(data)
        return true
    }

    /// 写入纯文本
    private func writePlainText(_ data: PasteboardModel) {
        var text = data.plainText
        if PasteUserDefaults.removeTailingNewline {
            text = text.trimmingTrailingNewlines()
        }
        NSPasteboard.general.setString(text, forType: .string)
    }

    /// 写入文件 URL
    /// - Returns: 是否有有效文件写入
    private func writeFileURLs(_ data: PasteboardModel) -> Bool {
        guard let filePaths = String(data: data.loadRawData(cache: false), encoding: .utf8) else {
            return false
        }

        let fileManager = FileManager.default
        let validURLs =
            filePaths
                .components(separatedBy: "\n")
                .lazy
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty && fileManager.fileExists(atPath: $0) }
                .map { URL(fileURLWithPath: $0) }

        let urlArray = Array(validURLs)
        guard !urlArray.isEmpty else { return false }

        pasteboard.writeObjects(urlArray as [NSPasteboardWriting])
        return true
    }

    /// 写入原始数据（富文本、图片等）
    private func writeRawData(_ data: PasteboardModel) {
        let payload = data.loadRawData(cache: false)
        guard !payload.isEmpty else {
            Log.pasteboard.warn("写入剪贴板跳过：二进制数据为空 (id: \(data.id ?? -1), uniqueId: \(data.uniqueId))")
            return
        }

        // 处理需要去除末尾换行的富文本
        if data.pasteboardType.isText(),
           PasteUserDefaults.removeTailingNewline,
           let attributedString = NSAttributedString(
               with: payload,
               type: data.pasteboardType
           ) {
            let mutableString = NSMutableAttributedString(
                attributedString: attributedString
            )
            mutableString.trimTrailingNewlines()

            if let processedData = mutableString.toData(
                with: data.pasteboardType
            ) {
                NSPasteboard.general.setData(
                    processedData,
                    forType: data.pasteboardType
                )
                return
            }
        }

        NSPasteboard.general.setData(payload, forType: data.pasteboardType)
    }
}

// MARK: - NSMutableAttributedString Extension

extension NSMutableAttributedString {
    func trimTrailingNewlines() {
        var currentLength = length
        let scalars = string.unicodeScalars
        var index = scalars.endIndex
        while index > scalars.startIndex {
            let prev = scalars.index(before: index)
            let val = scalars[prev].value
            if val == 0x0A || val == 0x0D { // '\n' or '\r'
                index = prev
                currentLength -= 1
            } else {
                break
            }
        }

        if currentLength < length {
            deleteCharacters(
                in: NSRange(
                    location: currentLength,
                    length: length - currentLength
                )
            )
        }
    }
}
