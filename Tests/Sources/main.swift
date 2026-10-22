//
//  main.swift
//  Tests
//
//  Entry point for Clipboard Unit Test suite (Swift Testing / SPM).
//

import Foundation

@MainActor
final class TestRunner {
    static var testsRun = 0
    static var testsPassed = 0

    static func assertEqual<T: Equatable>(_ actual: T, _ expected: T, _ message: String = "", file: StaticString = #file, line: UInt = #line) {
        testsRun += 1
        if actual != expected {
            print("❌ Assertion failed: expected [\(expected)], got [\(actual)]. \(message) at \(file):\(line)")
            exit(1)
        }
        testsPassed += 1
    }

    static func assertTrue(_ condition: Bool, _ message: String = "", file: StaticString = #file, line: UInt = #line) {
        testsRun += 1
        if !condition {
            print("❌ Assertion failed: expected true, got false. \(message) at \(file):\(line)")
            exit(1)
        }
        testsPassed += 1
    }

    static func assertFalse(_ condition: Bool, _ message: String = "", file: StaticString = #file, line: UInt = #line) {
        testsRun += 1
        if condition {
            print("❌ Assertion failed: expected false, got true. \(message) at \(file):\(line)")
            exit(1)
        }
        testsPassed += 1
    }

    static func main() {
        print("=== Running Clipboard Unit Tests ===")

        testSearchTextNormalizer()
        testJSONTransformer()
        SchemaMigrationTests.run(runner: TestRunner.self)
        CRUDOperationTests.run(runner: TestRunner.self)
        UndoRestoreTests.run(runner: TestRunner.self)
        FTSTriggerTests.run(runner: TestRunner.self)
        FilterStateTests.run(runner: TestRunner.self)
        PaginationTests.run(runner: TestRunner.self)
        ClipContentRendererTests.run(runner: TestRunner.self)
        CodeDetectorTests.run(runner: TestRunner.self)
        CodeHighlighterTests.run(runner: TestRunner.self)
        CodePerformanceTests.run(runner: TestRunner.self)
        CategoryChipTests.run(runner: TestRunner.self)
        PasteboardMonitoringTests.run(runner: TestRunner.self)
        EscapeHandlingTests.run(runner: TestRunner.self)
        QuickTransformServiceTests.run(runner: TestRunner.self)
        QuickPasteShortcutTests.run(runner: TestRunner.self)
        SystemEnergyMonitorTests.run(runner: TestRunner.self)

        print("\n==================================")
        print("🎉 All \(testsPassed)/\(testsRun) unit tests passed successfully!")
        print("==================================")
    }

    static func testSearchTextNormalizer() {
        print("\n--- Testing SearchTextNormalizer ---")

        // 1. Basic text normalization (strips whitespace and punctuation)
        assertEqual(SearchTextNormalizer.normalize("hello world"), "helloworld", "Should drop spaces")
        assertEqual(SearchTextNormalizer.normalize("hello-world"), "helloworld", "Should drop hyphens")
        assertEqual(SearchTextNormalizer.normalize("hello_world"), "helloworld", "Should drop underscores")
        assertEqual(SearchTextNormalizer.normalize("100% done"), "100done", "Should drop % symbol")

        // 2. URL normalization (preserves mathSymbol like = and drops punctuation like :, /, ., ?)
        assertEqual(SearchTextNormalizer.normalize("https://example.com/path?arg=1"), "httpsexamplecompatharg=1", "Should strip URL punctuation while preserving math symbols")

        // 3. CJK and full-width characters
        assertEqual(SearchTextNormalizer.normalize("剪贴板 历史 记录"), "剪贴板历史记录", "Should preserve CJK characters")
        assertEqual(SearchTextNormalizer.normalize("Hello 世界！"), "Hello世界", "Should drop full-width exclamation")

        // 4. Combined case with mixed characters
        assertEqual(SearchTextNormalizer.normalize("Test_123: Special-Chars & Spaces!"), "Test123SpecialCharsSpaces", "Mixed characters")
        assertEqual(SearchTextNormalizer.normalize(""), "", "Empty string")

        print("✓ SearchTextNormalizer tests passed!")
    }

    static func testJSONTransformer() {
        print("\n--- Testing JSONTransformer ---")

        // 1. Compact
        let prettyJSON = """
        {
          "name": "Clipboard",
          "version": 1
        }
        """
        do {
            let minified = try JSONTransformer.transform(prettyJSON, action: .compact)
            assertEqual(minified, "{\"name\":\"Clipboard\",\"version\":1}", "Should compact JSON")
        } catch {
            print("❌ JSON compact failed: \(error)")
            exit(1)
        }

        // 2. Format with 2 spaces
        let rawJSON = "{\"a\":1,\"b\":[true,false]}"
        do {
            let formatted2 = try JSONTransformer.transform(rawJSON, action: .format(.two))
            let expected2 = "{\n  \"a\": 1,\n  \"b\": [\n    true,\n    false\n  ]\n}"
            assertEqual(formatted2, expected2, "Should format with 2 spaces")
        } catch {
            print("❌ JSON format 2 spaces failed: \(error)")
            exit(1)
        }

        // 3. Format with 4 spaces
        do {
            let formatted4 = try JSONTransformer.transform(rawJSON, action: .format(.four))
            let expected4 = "{\n    \"a\": 1,\n    \"b\": [\n        true,\n        false\n    ]\n}"
            assertEqual(formatted4, expected4, "Should format with 4 spaces")
        } catch {
            print("❌ JSON format 4 spaces failed: \(error)")
            exit(1)
        }

        // 4. Key Naming: snake
        let camelJSON = "{\"userName\":\"JohnDoe\",\"userAge\":30}"
        do {
            let snakeFormatted = try JSONTransformer.transform(camelJSON, action: .renameKeys(.snake, indentation: .four))
            assertTrue(snakeFormatted.contains("\"user_name\""), "Keys should be converted to snake_case")
            assertTrue(snakeFormatted.contains("\"user_age\""), "Keys should be converted to snake_case")
        } catch {
            print("❌ JSON renameKeys to snake failed: \(error)")
            exit(1)
        }

        // 5. Invalid JSON error handling
        let invalidJSON = "{ unquoted_key: 123 }"
        var errorThrown = false
        do {
            _ = try JSONTransformer.transform(invalidJSON, action: .compact)
        } catch let err as JSONTransformError {
            errorThrown = true
            assertEqual(err, .invalidJSON, "Should catch invalidJSON error")
        } catch {
            print("❌ Unexpected error caught: \(error)")
            exit(1)
        }
        assertTrue(errorThrown, "Should fail on invalid JSON")

        print("✓ JSONTransformer tests passed!")
    }
}

TestRunner.main()
