//
//  MarkdownHTMLRenderer.swift
//  Clipboard
//
//  将 Markdown 渲染为等待 DOMPurify 清理的预览 HTML。
//

import Foundation

nonisolated enum MarkdownHTMLRenderer {
    /// 关闭时只允许内嵌 data: 图片；远程与本地文件都不加载。
    /// 预览内容来自剪贴板，属于不可信输入，不应主动发起请求。
    private static var contentSecurityPolicy: String {
        let mediaSources = PasteUserDefaults.enableRemoteImages
            ? "data: file: http: https:"
            : "data:"
        return """
        default-src 'none'; img-src \(mediaSources); media-src \(mediaSources); \
        style-src 'unsafe-inline'; font-src data:; script-src 'none'; frame-src 'none'; object-src 'none'; \
        connect-src 'none'; base-uri 'none'; form-action 'none'
        """
    }

    static func htmlDocument(for markdown: String) -> String {
        let body = MarkdownDocumentRenderer.render(markdown)
        let embeddedBody = escapeEmbeddedHTML(body)
        return """
        <!doctype html>
        <html>
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1.0">
        <meta http-equiv="Content-Security-Policy" content="\(contentSecurityPolicy)">
        <style>\(stylesheet)</style>
        </head>
        <body>
        <textarea id="markdown-source" hidden>\(embeddedBody)</textarea>
        <article id="markdown-content"></article>
        </body>
        </html>
        """
    }

    private static func escapeEmbeddedHTML(_ html: String) -> String {
        var output = ""
        output.reserveCapacity(html.count)

        for character in html {
            switch character {
            case "&":
                output += "&amp;"
            case "<":
                output += "&lt;"
            case ">":
                output += "&gt;"
            default:
                output.append(character)
            }
        }
        return output
    }
}
