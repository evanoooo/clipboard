//
//  JSONSyntaxHighlighter.swift
//  Clipboard
//

import Foundation

enum JSONSyntaxHighlighter {
    nonisolated enum Kind: Sendable {
        case key
        case string
        case number
        case literal
        case punctuation
    }

    nonisolated struct Span: Sendable {
        let range: NSRange
        let kind: Kind
    }

    nonisolated static func spans(
        in text: String,
        offset: Int
    ) -> [Span] {
        // 直接在 UTF-8 字节上扫描，避免桥接为 NSString（UTF-16）时产生额外内存分配。
        // JSON 结构字符（引号、冒号、括号等）均为 ASCII，UTF-8 字节偏移与 UTF-16 代码单元偏移
        // 在纯 ASCII 段完全一致；字符串内容可能含多字节序列，因此同时维护 utf16Offset 计数器。
        var source = text
        return source.withUTF8 { bytes in
            let count = bytes.count
            var result: [Span] = []
            result.reserveCapacity(max(16, count / 12))
            var byteIndex = 0    // UTF-8 字节索引
            var utf16Offset = 0  // 对应的 UTF-16 代码单元偏移

            /// 推进 byteIndex / utf16Offset 步进 n 个字节（均为 ASCII）
            @inline(__always)
            func advanceASCII(_ n: Int = 1) {
                byteIndex += n
                utf16Offset += n
            }

            /// 步进一个任意 UTF-8 编码单元，并同步 utf16Offset
            @inline(__always)
            func advanceOne() {
                let b = bytes[byteIndex]
                byteIndex += 1
                // UTF-8 多字节序列首字节规则：
                //   0xxxxxxx (0x00-0x7F) → 1 字节 → 1 个 UTF-16 代码单元
                //   110xxxxx (0xC0-0xDF) → 2 字节 → 1 个 UTF-16 代码单元
                //   1110xxxx (0xE0-0xEF) → 3 字节 → 1 个 UTF-16 代码单元
                //   11110xxx (0xF0-0xF7) → 4 字节 → 2 个 UTF-16 代码单元（代理对）
                // 续字节 (0x80-0xBF) 不产生新的代码单元，直接跳过
                if b & 0xC0 == 0x80 {
                    // 续字节：不增加 utf16Offset
                } else if b & 0xF8 == 0xF0 {
                    // 4 字节首字节（代理对）
                    utf16Offset += 2
                } else {
                    utf16Offset += 1
                }
            }

            while byteIndex < count {
                if shouldCancel(at: byteIndex) {
                    return []
                }
                let byte = bytes[byteIndex]

                if byte == 0x22 { // quote
                    let startUtf16 = utf16Offset
                    advanceASCII()
                    var escaped = false
                    while byteIndex < count {
                        if shouldCancel(at: byteIndex) {
                            return []
                        }
                        let cur = bytes[byteIndex]
                        advanceOne()
                        if escaped {
                            escaped = false
                        } else if cur == 0x5C { // backslash
                            escaped = true
                        } else if cur == 0x22 { // quote
                            break
                        }
                    }

                    // 向前看是否紧跟冒号（可能中间有空白）
                    var lookaheadByte = byteIndex
                    while lookaheadByte < count,
                          isWhitespaceByte(bytes[lookaheadByte])
                    {
                        lookaheadByte += 1
                    }
                    let kind: Kind = lookaheadByte < count
                        && bytes[lookaheadByte] == 0x3A // colon
                        ? .key
                        : .string
                    result.append(Span(
                        range: NSRange(location: offset + startUtf16, length: utf16Offset - startUtf16),
                        kind: kind
                    ))
                    continue
                }

                if byte == 0x2D || isDigitByte(byte) { // minus or digit
                    let startUtf16 = utf16Offset
                    advanceASCII()
                    while byteIndex < count, isNumberCharByte(bytes[byteIndex]) {
                        advanceASCII()
                    }
                    result.append(Span(
                        range: NSRange(location: offset + startUtf16, length: utf16Offset - startUtf16),
                        kind: .number
                    ))
                    continue
                }

                if isLiteralStartByte(byte) { // t, f, n
                    let startUtf16 = utf16Offset
                    advanceASCII()
                    while byteIndex < count, isASCIILetterByte(bytes[byteIndex]) {
                        advanceASCII()
                    }
                    result.append(Span(
                        range: NSRange(location: offset + startUtf16, length: utf16Offset - startUtf16),
                        kind: .literal
                    ))
                    continue
                }

                if isPunctuationByte(byte) {
                    result.append(Span(
                        range: NSRange(location: offset + utf16Offset, length: 1),
                        kind: .punctuation
                    ))
                }
                advanceOne()
            }

            return result
        }
    }

    private nonisolated static func shouldCancel(at index: Int) -> Bool {
        index.isMultiple(of: 4096)
            && withUnsafeCurrentTask { $0?.isCancelled ?? false }
    }

    @inline(__always)
    private nonisolated static func isWhitespaceByte(_ b: UInt8) -> Bool {
        b == 0x20 || b == 0x09 || b == 0x0A || b == 0x0D
    }

    @inline(__always)
    private nonisolated static func isDigitByte(_ b: UInt8) -> Bool {
        b >= 0x30 && b <= 0x39
    }

    @inline(__always)
    private nonisolated static func isNumberCharByte(_ b: UInt8) -> Bool {
        isDigitByte(b) || b == 0x2D || b == 0x2B || b == 0x2E || b == 0x65 || b == 0x45
    }

    @inline(__always)
    private nonisolated static func isLiteralStartByte(_ b: UInt8) -> Bool {
        b == 0x74 || b == 0x66 || b == 0x6E // t, f, n
    }

    @inline(__always)
    private nonisolated static func isASCIILetterByte(_ b: UInt8) -> Bool {
        (b >= 0x61 && b <= 0x7A) || (b >= 0x41 && b <= 0x5A)
    }

    @inline(__always)
    private nonisolated static func isPunctuationByte(_ b: UInt8) -> Bool {
        b == 0x7B || b == 0x7D || b == 0x5B || b == 0x5D || b == 0x3A || b == 0x2C
    }
}
