import Foundation

@MainActor
struct TestRunner {
    static var testsRun = 0
    static var testsPassed = 0

    static func assertEqual<T: Equatable>(_ actual: T, _ expected: T, _ message: String = "", file: StaticString = #file, line: UInt = #line) {
        testsRun += 1
        if actual != expected {
            print("❌ Assertion failed: [\(actual)] != [\(expected)]. \(message) at \(file):\(line)")
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

        // 4. Numbers and alphanumeric
        assertEqual(SearchTextNormalizer.normalize("v1.2.3-beta"), "v123beta", "Should preserve alphanumeric")

        // 5. queryTokens
        assertEqual(SearchTextNormalizer.queryTokens("hello world"), ["hello", "world"], "Should split into tokens")
        assertEqual(SearchTextNormalizer.queryTokens("  hello   world  "), ["hello", "world"], "Should trim whitespace")
        assertEqual(SearchTextNormalizer.queryTokens("hello hello world"), ["hello", "world"], "Should deduplicate tokens")
        assertEqual(SearchTextNormalizer.queryTokens("... --- !!!"), [], "Should discard empty tokens")
        assertEqual(SearchTextNormalizer.queryTokens("swift 剪贴板"), ["swift", "剪贴板"], "Should handle mixed language tokens")

        print("✓ SearchTextNormalizer tests passed!")
    }

    static func testJSONTransformer() {
        print("\n--- Testing JSONTransformer ---")

        // 1. Detection
        assertTrue(JSONTransformer.looksLikeJSON("{\"name\": \"test\"}"), "Should detect JSON object")
        assertTrue(JSONTransformer.looksLikeJSON("  [1, 2, 3]  "), "Should detect JSON array")
        assertTrue(!JSONTransformer.looksLikeJSON("not a json"), "Should not detect regular text")

        // 2. Validation
        assertTrue(JSONTransformer.isValid("{\"name\": \"clip\", \"version\": 1}"), "Valid object")
        assertTrue(JSONTransformer.isValid("[1, true, null, \"hello\"]"), "Valid array")
        assertTrue(!JSONTransformer.isValid("{invalid json}"), "Invalid syntax")
        assertTrue(!JSONTransformer.isValid("{\"unclosed\": "), "Unclosed syntax")

        // 3. Compact formatting
        do {
            let pretty = "{\n  \"a\": 1,\n  \"b\": 2\n}"
            let compacted = try JSONTransformer.transform(pretty, action: .compact)
            assertEqual(compacted, "{\"a\":1,\"b\":2}", "Compaction should strip spaces")
        } catch {
            fatalError("Compact failed: \(error)")
        }

        // 4. Pretty formatting
        do {
            let compact = "{\"a\":1}"
            let formatted = try JSONTransformer.transform(compact, action: .format(.two))
            assertEqual(formatted, "{\n  \"a\": 1\n}", "Formatting with two spaces")
        } catch {
            fatalError("Format failed: \(error)")
        }

        // 5. Key sorting
        do {
            let unsorted = "{\"z\":1,\"a\":2,\"m\":3}"
            let sorted = try JSONTransformer.transform(unsorted, action: .sortKeys(ascending: true, indentation: .none))
            assertEqual(sorted, "{\n\"a\": 2,\n\"m\": 3,\n\"z\": 1\n}", "Keys should be sorted alphabetically with line breaks")
        } catch {
            fatalError("Sort keys failed: \(error)")
        }

        print("✓ JSONTransformer tests passed!")
    }
}

TestRunner.main()
