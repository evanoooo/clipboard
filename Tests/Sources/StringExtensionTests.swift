//
//  StringExtensionTests.swift
//  Tests
//
//  Unit tests for String smartWordCount without NaturalLanguage / Espresso dependency.
//

import Foundation

extension CharacterSet {
    nonisolated static let cjkUnifiedIdeographs =
        CharacterSet(charactersIn: "\u{4E00}" ... "\u{9FFF}")
}

extension String {
    nonisolated var smartWordCount: Int {
        var count = 0
        enumerateSubstrings(
            in: startIndex ..< endIndex,
            options: [.byWords, .substringNotRequired]
        ) { _, substringRange, _, _ in
            guard !withUnsafeCurrentTask(body: { $0?.isCancelled ?? false }) else { return }
            let token = self[substringRange]
            var cjkCount = 0
            var hasNonCJK = false
            for scalar in token.unicodeScalars {
                if CharacterSet.cjkUnifiedIdeographs.contains(scalar) {
                    cjkCount += 1
                } else if !CharacterSet.whitespacesAndNewlines.contains(scalar) && !CharacterSet.punctuationCharacters.contains(scalar) {
                    hasNonCJK = true
                }
            }
            count += cjkCount + (hasNonCJK ? 1 : 0)
        }
        return count
    }
}

@MainActor
final class StringExtensionTests {
    static func run(runner: TestRunner.Type) {
        print("\n--- Testing String smartWordCount ---")

        runner.assertEqual("".smartWordCount, 0, "Empty string should have 0 words")
        runner.assertEqual("Hello world".smartWordCount, 2, "Simple English words")
        runner.assertEqual("Hello, world! How are you?".smartWordCount, 5, "English with punctuation")
        runner.assertEqual("你好世界".smartWordCount, 4, "Chinese characters count individually")
        runner.assertEqual("你好，世界！这是一段测试。".smartWordCount, 10, "Chinese with punctuation")
        runner.assertEqual("Hello 世界".smartWordCount, 3, "Mixed English and Chinese")
        runner.assertEqual("iOS开发工程师".smartWordCount, 6, "Attached English and Chinese")
        runner.assertEqual("   \n\t   ".smartWordCount, 0, "Only whitespace")
        runner.assertEqual("123 456".smartWordCount, 2, "Numbers")

        print("✓ String smartWordCount tests passed!")
    }
}
