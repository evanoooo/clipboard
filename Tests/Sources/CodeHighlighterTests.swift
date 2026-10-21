//
//  CodeHighlighterTests.swift
//  Tests
//
//  Unit tests for TextKit CodeHighlighter and dynamic appearance theme.
//

import AppKit
import Foundation

@MainActor
enum CodeHighlighterTests {
    static func run(runner: TestRunner.Type) {
        print("\n--- Testing CodeHighlighter & CodeTheme ---")
        testNginxSyntaxHighlighting(runner: runner)
        testNginxVariableHighlighting(runner: runner)
        testCommentAndStringHighlighting(runner: runner)
        testSearchKeywordHighlightMerge(runner: runner)
        testSafeBoundsHandling(runner: runner)
        print("✓ CodeHighlighter tests passed!")
    }

    private static func testNginxSyntaxHighlighting(runner: TestRunner.Type) {
        let code = "server { listen 80; proxy_pass http://backend; gzip on; }"
        let theme = CodeTheme()
        let attributed = CodeHighlighter.highlight(code, language: .nginx, theme: theme)

        let string = attributed.string as NSString
        let serverRange = string.range(of: "server")
        let listenRange = string.range(of: "listen")
        let proxyPassRange = string.range(of: "proxy_pass")
        let onRange = string.range(of: "on")
        let portRange = string.range(of: "80")

        runner.assertTrue(serverRange.location != NSNotFound, "Should find 'server'")
        runner.assertTrue(listenRange.location != NSNotFound, "Should find 'listen'")
        runner.assertTrue(proxyPassRange.location != NSNotFound, "Should find 'proxy_pass'")
        runner.assertTrue(onRange.location != NSNotFound, "Should find 'on'")
        runner.assertTrue(portRange.location != NSNotFound, "Should find '80'")

        // 验证 server 为关键字颜色
        let serverColor = attributed.attribute(.foregroundColor, at: serverRange.location, effectiveRange: nil) as? NSColor
        runner.assertTrue(serverColor == theme.color(for: .keyword), "server 应该是 keyword 颜色")

        // 验证 proxy_pass 为关键字颜色
        let proxyPassColor = attributed.attribute(.foregroundColor, at: proxyPassRange.location, effectiveRange: nil) as? NSColor
        runner.assertTrue(proxyPassColor == theme.color(for: .keyword), "proxy_pass 应该是 keyword 颜色")

        // 验证 on 为字面量颜色
        let onColor = attributed.attribute(.foregroundColor, at: onRange.location, effectiveRange: nil) as? NSColor
        runner.assertTrue(onColor == theme.color(for: .literal), "on 应该是 literal 颜色")

        // 验证 80 为数字颜色
        let portColor = attributed.attribute(.foregroundColor, at: portRange.location, effectiveRange: nil) as? NSColor
        runner.assertTrue(portColor == theme.color(for: .number), "80 应该是 number 颜色")
    }

    private static func testNginxVariableHighlighting(runner: TestRunner.Type) {
        let code = "proxy_set_header Host $host; set $custom_var 1;"
        let theme = CodeTheme()
        let attributed = CodeHighlighter.highlight(code, language: .nginx, theme: theme)

        let string = attributed.string as NSString
        let hostRange = string.range(of: "$host")
        let customVarRange = string.range(of: "$custom_var")

        runner.assertTrue(hostRange.location != NSNotFound, "Should find '$host'")
        runner.assertTrue(customVarRange.location != NSNotFound, "Should find '$custom_var'")

        let hostColor = attributed.attribute(.foregroundColor, at: hostRange.location, effectiveRange: nil) as? NSColor
        runner.assertTrue(hostColor == theme.color(for: .variable), "$host 应该是 variable 颜色")

        let customVarColor = attributed.attribute(.foregroundColor, at: customVarRange.location, effectiveRange: nil) as? NSColor
        runner.assertTrue(customVarColor == theme.color(for: .variable), "$custom_var 应该是 variable 颜色")
    }

    private static func testCommentAndStringHighlighting(runner: TestRunner.Type) {
        let code = """
        # Nginx main config
        user nginx;
        error_log /var/log/nginx/error.log warn;
        location /api {
            return 200 "OK";
        }
        """
        let theme = CodeTheme()
        let attributed = CodeHighlighter.highlight(code, language: .nginx, theme: theme)

        let string = attributed.string as NSString
        let commentRange = string.range(of: "# Nginx main config")
        let stringLiteralRange = string.range(of: "\"OK\"")

        runner.assertTrue(commentRange.location != NSNotFound, "Should find comment")
        runner.assertTrue(stringLiteralRange.location != NSNotFound, "Should find string literal")

        let commentColor = attributed.attribute(.foregroundColor, at: commentRange.location, effectiveRange: nil) as? NSColor
        runner.assertTrue(commentColor == theme.color(for: .comment), "注释应为 comment 颜色")

        let strColor = attributed.attribute(.foregroundColor, at: stringLiteralRange.location, effectiveRange: nil) as? NSColor
        runner.assertTrue(strColor == theme.color(for: .string), "字符串字面量应为 string 颜色")
    }

    private static func testSearchKeywordHighlightMerge(runner: TestRunner.Type) {
        let code = "proxy_pass http://127.0.0.1:8080;"
        let theme = CodeTheme()
        let attributed = CodeHighlighter.highlight(code, language: .nginx, theme: theme, keyword: "proxy")

        let string = attributed.string as NSString
        let proxyRange = string.range(of: "proxy")
        runner.assertTrue(proxyRange.location != NSNotFound, "Should find 'proxy'")

        // 验证前景色仍然是 keyword 颜色
        let fgColor = attributed.attribute(.foregroundColor, at: proxyRange.location, effectiveRange: nil) as? NSColor
        runner.assertTrue(fgColor == theme.color(for: .keyword), "前景色仍应保留关键字颜色")

        // 验证背景色被赋予了搜索黄色高亮
        let bgColor = attributed.attribute(.backgroundColor, at: proxyRange.location, effectiveRange: nil) as? NSColor
        runner.assertTrue(bgColor != nil, "背景色应该包含搜索高亮")
    }

    private static func testSafeBoundsHandling(runner: TestRunner.Type) {
        // 空字符串处理
        let emptyAttributed = CodeHighlighter.highlight("", language: .nginx)
        runner.assertEqual(emptyAttributed.length, 0, "Empty string should result in empty attributed string")

        // 超大文本不会 crash
        let hugeCode = String(repeating: "worker_processes auto;\n", count: 2000)
        let hugeAttributed = CodeHighlighter.highlight(hugeCode, language: .nginx)
        runner.assertEqual(hugeAttributed.length, (hugeCode as NSString).length, "Length should match source")
    }
}
