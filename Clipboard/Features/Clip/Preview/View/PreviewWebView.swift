//
//  PreviewWebView.swift
//  Clipboard
//
//  链接网页预览。
//

import AppKit
import SnapKit
import WebKit

final class PreviewWebView: NSView, WKNavigationDelegate, WKUIDelegate, PreviewResettable {
    private let webView: WKWebView
    private let loadingIndicator: NSProgressIndicator
    private let errorLabel: NSTextField
    private let url: URL

    init(url: URL) {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false

        // 关键修复：中文 macOS 环境下 WebKit 默认 fallback 文本编码为 gb18030。
        // 当预览未显式声明 charset 的脚本/纯文本（如 .sh/.py/.txt/.json）或缺少 meta 的网页时，
        // 会导致 UTF-8 编码的中文被按 GBK 解码，呈现为经典乱码（例如 "涓€閿笂浼"）。
        // 将默认文本编码显式设为 "utf-8"；若页面/响应头有显式 charset，WebKit 仍会优先遵从。
        let encodingSelector = Selector(("_setDefaultTextEncodingName:"))
        if configuration.preferences.responds(to: encodingSelector) {
            configuration.preferences.perform(encodingSelector, with: "utf-8")
        }

        webView = WKWebView(frame: .zero, configuration: configuration)
        loadingIndicator = NSProgressIndicator()
        errorLabel = NSTextField(wrappingLabelWithString: "")
        self.url = url
        super.init(frame: .zero)
        wantsLayer = true

        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.alphaValue = 0

        loadingIndicator.style = .spinning
        loadingIndicator.controlSize = .regular

        errorLabel.alignment = .center
        errorLabel.textColor = .secondaryLabelColor
        errorLabel.isHidden = true

        addSubview(webView)
        addSubview(loadingIndicator)
        addSubview(errorLabel)

        webView.snp.makeConstraints { $0.edges.equalToSuperview() }
        loadingIndicator.snp.makeConstraints { $0.center.equalToSuperview() }
        errorLabel.snp.makeConstraints { make in
            make.center.equalToSuperview()
            make.leading.greaterThanOrEqualToSuperview().offset(20)
            make.trailing.lessThanOrEqualToSuperview().offset(-20)
            make.width.lessThanOrEqualTo(360)
        }

        loadingIndicator.startAnimation(nil)
        webView.load(URLRequest(
            url: url,
            cachePolicy: .reloadIgnoringLocalAndRemoteCacheData,
            timeoutInterval: 10
        ))
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError()
    }

    func stopLoading() {
        webView.stopLoading()
        webView.navigationDelegate = nil
        webView.uiDelegate = nil
        webView.loadHTMLString("", baseURL: nil)
    }

    func resetPreview() {
        stopLoading()
    }

    func webView(_: WKWebView, didFinish _: WKNavigation!) {
        inspectContent()
    }

    func webView(_: WKWebView, didFail _: WKNavigation!, withError error: Error) {
        show(error)
    }

    func webView(_: WKWebView, didFailProvisionalNavigation _: WKNavigation!, withError error: Error) {
        show(error)
    }

    // MARK: - 导航边界

    private static let externalSchemes: Set<String> = ["http", "https", "mailto"]

    /// 与 `PreviewMarkdownView` 保持一致：只拦截用户点击的链接，
    /// 重定向与脚本跳转交给页面，避免把预览变成“什么都点不动”。
    func webView(
        _: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void
    ) {
        guard navigationAction.navigationType == .linkActivated else {
            decisionHandler(.allow)
            return
        }

        guard let url = navigationAction.request.url,
              Self.externalSchemes.contains(url.scheme?.lowercased() ?? "")
        else {
            decisionHandler(.cancel)
            return
        }

        NSWorkspace.shared.open(url)
        decisionHandler(.cancel)
    }

    /// `target=_blank` / `window.open`：不开新窗口，交给系统浏览器。
    func webView(
        _: WKWebView,
        createWebViewWith _: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction,
        windowFeatures _: WKWindowFeatures
    ) -> WKWebView? {
        if let url = navigationAction.request.url,
           Self.externalSchemes.contains(url.scheme?.lowercased() ?? "") {
            NSWorkspace.shared.open(url)
        }
        return nil
    }

    private func show(_ error: Error) {
        let nsError = error as NSError
        log.error(
            "[linkPreview] 加载失败 host=\(url.host() ?? "-") "
                + "domain=\(nsError.domain) code=\(nsError.code) desc=\(nsError.localizedDescription)"
        )
        loadingIndicator.stopAnimation(nil)
        loadingIndicator.isHidden = true
        errorLabel.stringValue = String(localized: .linkPreviewFailed(nsError.localizedDescription))
        errorLabel.isHidden = false
        webView.alphaValue = 0
    }

    /// 加载“成功”但页面无可见内容时（常见于反爬拦截页或重定向壳），不要把白屏当成功。
    private func inspectContent() {
        let script = """
        (function() {
          var body = document.body;
          if (!body) { return { title: document.title || "", text: -1, media: 0 }; }
          var text = (body.innerText || "").trim();
          var media = document.images.length +
            document.querySelectorAll('video,canvas,svg,iframe,object,embed').length;
          return { title: document.title || "", text: text.length, media: media };
        })();
        """

        webView.evaluateJavaScript(script) { [weak self] result, _ in
            guard let self else { return }
            let payload = result as? [String: Any]
            let title = payload?["title"] as? String ?? ""
            let textLength = (payload?["text"] as? NSNumber)?.intValue ?? -1
            let mediaCount = (payload?["media"] as? NSNumber)?.intValue ?? 0

            log.info(
                "[linkPreview] 加载完成 host=\(url.host() ?? "-") titleLen=\(title.count) "
                    + "textLen=\(textLength) media=\(mediaCount)"
            )

            if textLength == 0, mediaCount == 0 {
                loadingIndicator.stopAnimation(nil)
                loadingIndicator.isHidden = true
                errorLabel.stringValue = String(localized: .linkPreviewEmpty)
                errorLabel.isHidden = false
                webView.alphaValue = 0
            } else {
                finishLoading()
            }
        }
    }

    private func finishLoading() {
        loadingIndicator.stopAnimation(nil)
        loadingIndicator.isHidden = true
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.2
            webView.animator().alphaValue = 1
        }
    }
}
