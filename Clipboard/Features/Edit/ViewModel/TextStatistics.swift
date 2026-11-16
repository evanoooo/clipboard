//
//  TextStatistics.swift
//  Clipboard
//
//  Created by crown on 2025/12/28.
//

import Foundation

/// 文本统计信息（字符数 / 词数 / 行数）
struct TextStatistics: Equatable, Sendable {
    let characterCount: Int
    let wordCount: Int
    let lineCount: Int

    nonisolated init(from text: String, lineCount knownLineCount: Int? = nil) {
        if text.isEmpty {
            characterCount = 0
            wordCount = 0
            lineCount = 0
            return
        }

        // 大文本采用单趟扫描同时计算词数与行数，避免多遍全量遍历
        if text.utf8.count > 50_000 {
            var chars = 0
            var words = 0
            var lines = 1
            var inWord = false
            var prevCR = false
            var iter = 0

            for scalar in text.unicodeScalars {
                if (iter & 0xFFF) == 0, withUnsafeCurrentTask(body: { $0?.isCancelled ?? false }) {
                    break
                }
                iter &+= 1
                chars += 1
                let val = scalar.value
                if val == 0x0D { // \r
                    lines += 1
                    prevCR = true
                    if inWord { words += 1; inWord = false }
                    continue
                }
                if val == 0x0A { // \n
                    if !prevCR { lines += 1 }
                    prevCR = false
                    if inWord { words += 1; inWord = false }
                    continue
                }
                prevCR = false
                if val == 0x85 || val == 0x2028 || val == 0x2029 {
                    lines += 1
                    if inWord { words += 1; inWord = false }
                } else if val >= 0x4E00 && val <= 0x9FFF {
                    if inWord { words += 1; inWord = false }
                    words += 1
                } else if CharacterSet.alphanumerics.contains(scalar) {
                    inWord = true
                } else if inWord {
                    words += 1
                    inWord = false
                }
            }
            if inWord { words += 1 }
            characterCount = chars
            wordCount = words
            lineCount = knownLineCount ?? lines
            return
        }

        var source = text
        source.makeContiguousUTF8()
        characterCount = source.count
        wordCount = source.smartWordCount
        lineCount = knownLineCount ?? (source.count(where: { $0.isNewline }) + 1)
    }

    var displayString: String {
        String(localized: .textStats(characterCount, wordCount, lineCount))
    }
}
