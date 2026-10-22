//
//  MarkdownDetectorTests.swift
//  Tests
//
//  Unit tests for MarkdownDetector and the code-vs-markdown precedence.
//

import Foundation

@MainActor
enum MarkdownDetectorTests {
    static func run(runner: TestRunner.Type) {
        print("\n--- Testing MarkdownDetector ---")

        // 1. 普通 markdown 文档命中
        let markdownDoc = """
        # 标题

        - 第一项
        - 第二项
        """
        runner.assertTrue(MarkdownDetector.detect(markdownDoc), "Markdown document must be detected")
        runner.assertTrue(
            MarkdownDetector.usesMarkdownPreview(markdownDoc, isMarkdown: true, codeLanguage: nil),
            "Markdown document without code must use markdown preview"
        )

        // 2. 源码 docstring 里的列表会命中 markdown 特征
        let pythonSource = """
        #!/usr/bin/env python3
        \"\"\"把 Paste (Core Data) 数据库的内容导入 Clip 结构。

        兼容 Apple 全套格式：
          - 解压: LZVN (bvxn), LZFSE (bvx$), LZ4, zlib/raw deflate
          - 反序列化: Apple Binary plist (NSKeyedArchiver)
        \"\"\"

        import plistlib


        def read_archive(path):
            with open(path, "rb") as f:
                return plistlib.load(f)
        """
        runner.assertTrue(MarkdownDetector.detect(pythonSource), "Python docstring list still looks like markdown")
        runner.assertTrue(
            !MarkdownDetector.usesMarkdownPreview(pythonSource, isMarkdown: true, codeLanguage: .python),
            "Detected source code must not use markdown preview"
        )

        // 3. markdown 文档内嵌围栏代码块：仍按 markdown 渲染
        let docWithFence = """
        # 安装

        ```python
        def main():
            pass
        ```
        """
        runner.assertTrue(MarkdownDetector.containsFencedCodeBlock(docWithFence), "Fenced code block must be found")
        runner.assertTrue(
            MarkdownDetector.usesMarkdownPreview(docWithFence, isMarkdown: true, codeLanguage: .python),
            "Markdown document with fenced code must keep markdown preview"
        )

        // 4. 未识别为 markdown 的代码直接走代码视图
        runner.assertTrue(
            !MarkdownDetector.usesMarkdownPreview(pythonSource, isMarkdown: false, codeLanguage: .python),
            "Non-markdown code must not use markdown preview"
        )

        // 5. 普通散文不应命中 markdown
        let prose = "这是一篇关于剪贴板工具的普通笔记，用于记录今天的会议纪要和工作安排。"
        runner.assertTrue(!MarkdownDetector.detect(prose), "Normal prose must not be detected as markdown")

        print("✓ MarkdownDetector tests passed!")
    }
}
