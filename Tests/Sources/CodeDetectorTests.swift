//
//  CodeDetectorTests.swift
//  Tests
//
//  Unit tests for CodeLanguageDetector and language rules (including Nginx and Shell).
//

import Foundation

@MainActor
enum CodeDetectorTests {
    static func run(runner: TestRunner.Type) {
        print("\n--- Testing CodeLanguageDetector & Shell/Nginx Rules ---")

        // 1. Detect Nginx configuration
        let nginxSnippet = """
        server {
            listen 80;
            server_name api.example.com;

            location / {
                proxy_pass http://127.0.0.1:8080;
                proxy_set_header Host $host;
                proxy_set_header X-Real-IP $remote_addr;
            }
        }
        """
        let detectedNginx = CodeLanguageDetector.detect(nginxSnippet)
        runner.assertEqual(detectedNginx, .nginx, "Nginx config must be accurately detected")

        // 2. Detect Swift snippet
        let swiftSnippet = """
        import Foundation
        import SwiftUI

        struct MyViewModel {
            func fetchData() async {
                guard let url = URL(string: "https://example.com") else { return }
            }
        }
        """
        runner.assertEqual(CodeLanguageDetector.detect(swiftSnippet), .swift, "Swift code must be detected")

        // 3. Detect Python snippet
        let pythonSnippet = """
        def process_items(items):
            result = []
            for item in items:
                result.append(item * 2)
            return result

        if __name__ == '__main__':
            print("Done")
        """
        runner.assertEqual(CodeLanguageDetector.detect(pythonSnippet), .python, "Python code must be detected")

        // 4. Detect SQL query
        let sqlSnippet = """
        SELECT id, name, created_at
        FROM users
        WHERE status = 1
        ORDER BY created_at DESC;
        """
        runner.assertEqual(CodeLanguageDetector.detect(sqlSnippet), .sql, "SQL query must be detected")

        // 5. Detect JSON
        let jsonSnippet = """
        {
            "name": "clipboard",
            "version": 1,
            "enabled": true
        }
        """
        runner.assertEqual(CodeLanguageDetector.detect(jsonSnippet), .json, "JSON snippet must be detected")

        // 6. Detect Shell with Shebang
        let shellShebang = """
        #!/bin/bash
        set -euo pipefail
        echo "Building release package..."
        """
        runner.assertEqual(CodeLanguageDetector.detect(shellShebang), .bash, "Shebang shell script must be detected")

        // 7. Detect Shell control flow & commands
        let shellControl = """
        if [ -d "$TARGET_DIR" ]; then
            echo "Directory exists"
        else
            mkdir -p "$TARGET_DIR"
        fi
        """
        runner.assertEqual(CodeLanguageDetector.detect(shellControl), .bash, "Shell control structure must be detected")

        // 8. Detect Terminal commands & prompt
        let terminalPrompt = """
        $ git checkout -b feature/shell-highlight
        $ brew install cmake
        """
        runner.assertEqual(CodeLanguageDetector.detect(terminalPrompt), .bash, "Terminal prompt snippet must be detected")

        // 9. Natural language / Prose should NOT be detected as code
        let prose = "这是一篇关于剪贴板工具的普通笔记，用于记录今天的会议纪要和工作安排。"
        runner.assertTrue(CodeLanguageDetector.detect(prose) == nil, "Normal prose should return nil")

        let englishProse = "Hello everyone, please review the document and send me your feedback before Friday afternoon."
        runner.assertTrue(CodeLanguageDetector.detect(englishProse) == nil, "English prose should return nil")

        // 10. Short strings (< 4 chars) should return nil
        runner.assertTrue(CodeLanguageDetector.detect("hi") == nil, "Short text returns nil")

        // 11. Shebang 直接定语言：脚本开头是注释/文档字符串时，靠头部信号也能命中
        let pythonShebang = """
        #!/usr/bin/env python3
        \"\"\"导入 Paste (Core Data) 数据库。

        兼容 Apple 全套格式：
          - 解压: LZVN, LZFSE, LZ4, zlib/raw deflate
          - 反序列化: Apple Binary plist (NSKeyedArchiver)
        \"\"\"

        \(String(repeating: "# 说明：这里的头部说明很长，覆盖到 2000 字符之后才出现函数定义。\n", count: 80))

        def read_archive(path):
            with open(path, "rb") as f:
                return plistlib.load(f)
        """
        runner.assertEqual(CodeLanguageDetector.detect(pythonShebang), .python, "Python shebang must be detected even when def is far away")

        let nodeShebang = """
        #!/usr/bin/env node
        console.log("ready")
        """
        runner.assertEqual(CodeLanguageDetector.detect(nodeShebang), .javascript, "Node shebang must be detected as JavaScript")

        let rubyShebang = """
        #!/usr/bin/env ruby
        puts "ready"
        """
        runner.assertEqual(CodeLanguageDetector.detect(rubyShebang), .ruby, "Ruby shebang must be detected")

        // 12. 超长源码：只解码开头，仍能识别
        let longPython = "#!/usr/bin/env python3\n" + String(repeating: "# 注释填充\n", count: 6_000) + "def main():\n    pass\n"
        runner.assertTrue(longPython.count > 20_000, "Long python source should exceed the previous 20k cap")
        runner.assertEqual(CodeLanguageDetector.detect(Data(longPython.utf8)), .python, "Long python source must be detected from raw data")

        // 13. 解释器内联调用：外层是 shell 命令，内层源码没有可判别的头部信号
        let inlinePythonCommand = """
        python3 -c "
        import sqlite3, shutil

        # 1. 打开数据库并强制把 WAL 模式转为单文件 DELETE 模式
        conn = sqlite3.connect('out.sqlite3')
        check = conn.execute('PRAGMA integrity_check;').fetchone()[0]
        print(f'数据库完整性检查: {check}')
        "
        """
        runner.assertEqual(CodeLanguageDetector.detect(inlinePythonCommand), .bash, "python3 -c command must be detected as Shell")

        // 14. 去掉命令行外壳后，纯 Python 片段靠普通 import 命中
        let pythonBody = """
        import sqlite3, shutil

        # 1. 打开数据库并强制把 WAL 模式转为单文件 DELETE 模式
        conn = sqlite3.connect('out.sqlite3')
        check = conn.execute('PRAGMA integrity_check;').fetchone()[0]
        print(f'数据库完整性检查: {check}')
        """
        runner.assertEqual(CodeLanguageDetector.detect(pythonBody), .python, "Plain import statement must be detected as Python")

        // 15. 新增规则不应把普通说明文字误判
        runner.assertTrue(CodeLanguageDetector.detect("python3 3.11 的新特性") == nil, "Prose starting with python3 must not be detected as Shell")
        runner.assertTrue(CodeLanguageDetector.detect("import 导入模块的三种写法") == nil, "Prose starting with import must not be detected as Python")

        // 16. Display name verification
        runner.assertEqual(CodeLanguage.bash.displayName, "Shell", "Bash display name should be Shell")
        runner.assertEqual(CodeLanguage.nginx.displayName, "Nginx", "Nginx display name should be Nginx")
        runner.assertEqual(CodeLanguage.swift.displayName, "Swift", "Swift display name should be Swift")

                // 16. Multiline curl command with JSON payload must be detected as Shell (.bash)
        let curlCommand = """
        curl --url 'http://192.168.12.207/hecate/api/v1/agentos/sessions/fcda5b67-37ba-4c33-9b46-b533dabea75a/messages' \\
          -H 'Accept: application/json, text/plain, */*' \\
          -H 'Accept-Language: zh-CN' \\
          -H 'Content-Type: application/json' \\
          -b 'SESSION=YWYwMjBkMzgtYmYyMS00ODA1LWIzNTYtNjIxNTRhZjkzNDZj' \\
          -H 'Origin: http://192.168.12.207' \\
          -H 'Proxy-Connection: keep-alive' \\
          -H 'Referer: http://192.168.12.207/hecate' \\
          -H 'User-Agent: Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7)' \\
          --data-raw '{"blocks":[{"type":"text","content":"你是哪个大模型啊"}]}' \\
          --insecure
        """
        runner.assertEqual(CodeLanguageDetector.detect(curlCommand), .bash, "Multiline curl command must be detected as Shell")

        print("✓ CodeLanguageDetector & Shell/Nginx tests passed!")
    }
}
