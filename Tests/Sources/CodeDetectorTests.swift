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

        // 11. Display name verification
        runner.assertEqual(CodeLanguage.bash.displayName, "Shell", "Bash display name should be Shell")
        runner.assertEqual(CodeLanguage.nginx.displayName, "Nginx", "Nginx display name should be Nginx")
        runner.assertEqual(CodeLanguage.swift.displayName, "Swift", "Swift display name should be Swift")

        print("✓ CodeLanguageDetector & Shell/Nginx tests passed!")
    }
}
