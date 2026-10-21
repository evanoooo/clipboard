//
//  CodePerformanceTests.swift
//  Tests
//
//  End-to-end syntax highlighting test suite and performance baseline benchmarks.
//

import AppKit
import Foundation

@MainActor
enum CodePerformanceTests {
    static func run(runner: TestRunner.Type) {
        print("\n--- Testing Code Highlight E2E & Performance Baselines ---")
        testComplexNestedNginxConfiguration(runner: runner)
        testUnclosedDelimitersAndEdgeCases(runner: runner)
        testUnicodeAndEmojiSafety(runner: runner)
        testMultiLanguageLexicalHighlighting(runner: runner)
        testPerformanceBenchmark(runner: runner)
        print("✓ Code Highlight E2E & Performance tests passed!")
    }

    // MARK: - 1. 复杂多层嵌套 Nginx 配置端到端断言

    private static func testComplexNestedNginxConfiguration(runner: TestRunner.Type) {
        let complexNginx = """
        user nginx;
        worker_processes auto;
        error_log /var/log/nginx/error.log warn;
        pid /var/run/nginx.pid;

        events {
            worker_connections 1024;
            multi_accept on;
        }

        http {
            include /etc/nginx/mime.types;
            default_type application/octet-stream;

            upstream backend_api {
                server 10.0.0.1:8080 max_fails=3 fail_timeout=10s;
                server 10.0.0.2:8080 weight=2;
                keepalive 32;
            }

            server {
                listen 443 ssl http2;
                server_name example.com *.example.com;

                ssl_certificate /etc/ssl/cert.pem;
                ssl_certificate_key /etc/ssl/key.pem;

                location /api/v1/ {
                    # Proxy settings
                    proxy_pass http://backend_api;
                    proxy_set_header Host $host;
                    proxy_set_header X-Real-IP $remote_addr;
                    proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
                    proxy_set_header X-Custom-Header ${http_custom_token};

                    proxy_connect_timeout 5s;
                    proxy_read_timeout 60s;
                    gzip on;
                }

                location /health {
                    return 200 "OK\\n";
                }
            }
        }
        """

        let theme = CodeTheme()
        let attributed = CodeHighlighter.highlight(complexNginx, language: .nginx, theme: theme, keyword: "backend_api")
        let string = attributed.string as NSString

        // 验证结构指令
        let httpRange = string.range(of: "http {")
        let upstreamRange = string.range(of: "upstream backend_api")
        let listenRange = string.range(of: "listen 443")
        let locationRange = string.range(of: "location /api/v1/")

        runner.assertTrue(httpRange.location != NSNotFound, "Should find 'http'")
        runner.assertTrue(upstreamRange.location != NSNotFound, "Should find 'upstream'")
        runner.assertTrue(listenRange.location != NSNotFound, "Should find 'listen'")
        runner.assertTrue(locationRange.location != NSNotFound, "Should find 'location'")

        // 验证变量
        let hostVarRange = string.range(of: "$host")
        let remoteAddrRange = string.range(of: "$remote_addr")
        let bracedVarRange = string.range(of: "${http_custom_token}")

        runner.assertTrue(hostVarRange.location != NSNotFound, "Should find '$host'")
        runner.assertTrue(remoteAddrRange.location != NSNotFound, "Should find '$remote_addr'")
        runner.assertTrue(bracedVarRange.location != NSNotFound, "Should find '${http_custom_token}'")

        let hostColor = attributed.attribute(.foregroundColor, at: hostVarRange.location, effectiveRange: nil) as? NSColor
        runner.assertTrue(hostColor == theme.color(for: .variable), "$host 应为变量颜色")

        let bracedVarColor = attributed.attribute(.foregroundColor, at: bracedVarRange.location, effectiveRange: nil) as? NSColor
        runner.assertTrue(bracedVarColor == theme.color(for: .variable), "${http_custom_token} 应为变量颜色")

        // 验证搜索词背景高亮合成
        let searchHit = string.range(of: "backend_api")
        let searchBgColor = attributed.attribute(.backgroundColor, at: searchHit.location, effectiveRange: nil) as? NSColor
        runner.assertTrue(searchBgColor != nil, "搜索词 backend_api 应该叠加背景高亮")
    }

    // MARK: - 2. 异常与未闭合定界符边界健壮性

    private static func testUnclosedDelimitersAndEdgeCases(runner: TestRunner.Type) {
        // 未闭合字符串
        let unclosedString = "server { return 200 \"this string never closes;\n proxy_pass http://localhost; }"
        let attr1 = CodeHighlighter.highlight(unclosedString, language: .nginx)
        runner.assertEqual(attr1.length, (unclosedString as NSString).length, "未闭合字符串应平稳扫描至文末或换行")

        // 未闭合块注释
        let unclosedBlock = "/* unclosed comment starts here\n func test() {}"
        let attr2 = CodeHighlighter.highlight(unclosedBlock, language: .swift)
        runner.assertEqual(attr2.length, (unclosedBlock as NSString).length, "未闭合块注释应平稳完成")

        // 未闭合变量花括号
        let unclosedBrace = "set ${unclosed_var value;"
        let attr3 = CodeHighlighter.highlight(unclosedBrace, language: .nginx)
        runner.assertEqual(attr3.length, (unclosedBrace as NSString).length, "未闭合变量花括号应平稳完成")

        // 纯空白与空字符
        let whitespaceOnly = "   \n\t  \r\n   "
        let attr4 = CodeHighlighter.highlight(whitespaceOnly, language: .nginx)
        runner.assertEqual(attr4.length, (whitespaceOnly as NSString).length, "纯空白文本处理安全")
    }

    // MARK: - 3. Unicode 与 Emoji 混合编码安全性

    private static func testUnicodeAndEmojiSafety(runner: TestRunner.Type) {
        let unicodeText = """
        # 这是中文注释 🚀 和多字节符号 ∑(x)
        server {
            listen 80; # 监听端口 🌐
            set $user_name "张三 👨‍👩‍👧‍👦";
            return 200 "你好，世界！✨";
        }
        """

        let theme = CodeTheme()
        let attributed = CodeHighlighter.highlight(unicodeText, language: .nginx, theme: theme, keyword: "张三")
        let string = attributed.string as NSString

        runner.assertEqual(attributed.length, string.length, "UTF-16 长度必须精确吻合")

        let commentRange = string.range(of: "# 这是中文注释 🚀 和多字节符号 ∑(x)")
        runner.assertTrue(commentRange.location != NSNotFound, "Should locate unicode comment")
        let commentColor = attributed.attribute(.foregroundColor, at: commentRange.location, effectiveRange: nil) as? NSColor
        runner.assertTrue(commentColor == theme.color(for: .comment), "中文与 Emoji 注释应正确高亮")

        let keywordRange = string.range(of: "张三")
        runner.assertTrue(keywordRange.location != NSNotFound, "Should locate keyword")
        let searchBg = attributed.attribute(.backgroundColor, at: keywordRange.location, effectiveRange: nil) as? NSColor
        runner.assertTrue(searchBg != nil, "中文搜索命中应正确应用高亮背景")
    }

    // MARK: - 4. 跨语言语法着色验证

    private static func testMultiLanguageLexicalHighlighting(runner: TestRunner.Type) {
        let theme = CodeTheme()

        // JSON
        let json = "{\"name\": \"Clipboard\", \"count\": 100, \"active\": true}"
        let jsonAttr = CodeHighlighter.highlight(json, language: .json, theme: theme)
        let jsonStr = jsonAttr.string as NSString
        let trueRange = jsonStr.range(of: "true")
        let trueColor = jsonAttr.attribute(.foregroundColor, at: trueRange.location, effectiveRange: nil) as? NSColor
        runner.assertTrue(trueColor == theme.color(for: .literal), "JSON 布尔值应为 literal 颜色")

        // Swift
        let swift = "func processData(item: Item) -> Bool { return true }"
        let swiftAttr = CodeHighlighter.highlight(swift, language: .swift, theme: theme)
        let swiftStr = swiftAttr.string as NSString
        let funcRange = swiftStr.range(of: "func")
        let funcColor = swiftAttr.attribute(.foregroundColor, at: funcRange.location, effectiveRange: nil) as? NSColor
        runner.assertTrue(funcColor == theme.color(for: .keyword), "Swift func 应为 keyword 颜色")

        // SQL
        let sql = "SELECT id, name FROM users WHERE active = 1;"
        let sqlAttr = CodeHighlighter.highlight(sql, language: .sql, theme: theme)
        let sqlStr = sqlAttr.string as NSString
        let selectRange = sqlStr.range(of: "SELECT")
        let selectColor = sqlAttr.attribute(.foregroundColor, at: selectRange.location, effectiveRange: nil) as? NSColor
        runner.assertTrue(selectColor == theme.color(for: .keyword), "SQL SELECT 应为 keyword 颜色")
    }

    // MARK: - 5. 性能基准与吞吐量测试（Baseline Benchmark）

    private static func testPerformanceBenchmark(runner: TestRunner.Type) {
        // 生成约 10,000 字符的典型 Nginx 配置文件块
        let nginxBlock = """
        server {
            listen 80;
            server_name api.service.internal;
            client_max_body_size 50m;
            proxy_connect_timeout 10s;
            proxy_read_timeout 60s;
            proxy_send_timeout 60s;

            location /v1/resource {
                proxy_pass http://10.0.0.1:8080;
                proxy_set_header Host $host;
                proxy_set_header X-Real-IP $remote_addr;
                proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
                gzip on;
                gzip_types application/json text/plain;
            }
        }
        """

        let repeatCount = 20
        let largeNginx = String(repeating: nginxBlock + "\n", count: repeatCount)
        let totalChars = largeNginx.count
        runner.assertTrue(totalChars >= 8_000, "测试文本应达数千至上万字符规模")

        // 预热一次
        _ = CodeHighlighter.highlight(largeNginx, language: .nginx, keyword: "proxy_pass")

        // 连续运行 30 次测量平均耗时
        let iterations = 30
        let startTime = CFAbsoluteTimeGetCurrent()
        for _ in 0..<iterations {
            _ = CodeHighlighter.highlight(largeNginx, language: .nginx, keyword: "proxy_pass")
        }
        let totalElapsed = CFAbsoluteTimeGetCurrent() - startTime
        let averageMs = (totalElapsed / Double(iterations)) * 1000.0

        print("    [Benchmark] \(totalChars) chars, \(iterations) iterations: avg \(String(format: "%.2f", averageMs)) ms / run")

        // 性能基线：单次高亮渲染耗时必须严格 < 15ms（小于 60fps 单帧阈值 16.6ms）
        runner.assertTrue(averageMs < 15.0, "单次代码高亮平均耗时需小于 15ms (实际: \(averageMs)ms)")

        // 验证超过 30,000 字符时的安全截断
        let hugeText = String(repeating: largeNginx, count: 5)
        runner.assertTrue(hugeText.count > CodeHighlighter.maxHighlightLength, "超大文本超过安全截断阈值")
        let hugeAttr = CodeHighlighter.highlight(hugeText, language: .nginx)
        runner.assertEqual(hugeAttr.length, (hugeText as NSString).length, "超大文本平稳截断渲染，长度一致")
    }
}
