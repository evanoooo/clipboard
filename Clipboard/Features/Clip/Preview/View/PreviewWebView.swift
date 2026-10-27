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
    private var isDownloadBlocked = false

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
        isDownloadBlocked = false
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

    // MARK: - 导航与下载边界

    private static let externalSchemes: Set<String> = ["http", "https", "mailto"]

    /// 限制仅能预览简单网页，并彻底禁止触发下载动作。
    func webView(
        _: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void
    ) {
        // 坚决阻止下载请求
        if navigationAction.shouldPerformDownload {
            log.info("[linkPreview] 拦截 shouldPerformDownload 请求: \(navigationAction.request.url?.absoluteString ?? "-")")
            showDownloadBlocked()
            decisionHandler(.cancel)
            return
        }

        guard navigationAction.navigationType == .linkActivated else {
            // 对于非用户直接点击的跳转（如初始请求、重定向等），检测是否属于文件下载链接
            if let targetURL = navigationAction.request.url, !targetURL.isLikelySimpleWebPage {
                log.info("[linkPreview] 拦截非简单网页目标: \(targetURL.absoluteString)")
                showDownloadBlocked()
                decisionHandler(.cancel)
                return
            }
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

    /// 拦截服务器响应：防止文件下载响应，仅允许简单网页的 MIME 类型。
    func webView(
        _: WKWebView,
        decidePolicyFor navigationResponse: WKNavigationResponse,
        decisionHandler: @escaping @MainActor @Sendable (WKNavigationResponsePolicy) -> Void
    ) {
        // 1. 若 WebKit 原生无法直接展示（常见于压缩包、磁盘镜像、二进制文件等），绝对不能调用 .download
        guard navigationResponse.canShowMIMEType else {
            log.info("[linkPreview] 拦截 WebKit 不可展示的 MIME 类型: \(navigationResponse.response.mimeType ?? "")")
            showDownloadBlocked()
            decisionHandler(.cancel)
            return
        }

        // 2. 检查响应头 Content-Disposition 是否要求作为附件下载
        if let httpResponse = navigationResponse.response as? HTTPURLResponse,
           let disposition = httpResponse.value(forHTTPHeaderField: "Content-Disposition")?.lowercased(),
           disposition.contains("attachment") {
            log.info("[linkPreview] 拦截 Content-Disposition attachment: \(httpResponse.url?.absoluteString ?? "")")
            showDownloadBlocked()
            decisionHandler(.cancel)
            return
        }

        // 3. 限制只预览简单网页（MIME 类型必须为网页相关）
        if let mimeType = navigationResponse.response.mimeType {
            let cleanMime = mimeType.split(separator: ";").first?.trimmingCharacters(in: .whitespaces).lowercased() ?? ""
            let isSimpleWebMime = cleanMime == "text/html"
                || cleanMime == "application/xhtml+xml"
                || cleanMime == "text/plain"
            guard isSimpleWebMime else {
                log.info("[linkPreview] 拦截非简单网页 MIME 类型: \(cleanMime)")
                showDownloadBlocked()
                decisionHandler(.cancel)
                return
            }
        }

        decisionHandler(.allow)
    }

    /// 兜底防护：若任何途径生成了 WKDownload，立即取消，绝不下载任何文件到磁盘。
    func webView(_: WKWebView, navigationAction _: WKNavigationAction, didBecome download: WKDownload) {
        log.warn("[linkPreview] 强制取消 WKNavigationAction download")
        download.cancel()
        showDownloadBlocked()
    }

    func webView(_: WKWebView, navigationResponse _: WKNavigationResponse, didBecome download: WKDownload) {
        log.warn("[linkPreview] 强制取消 WKNavigationResponse download")
        download.cancel()
        showDownloadBlocked()
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

    private func showDownloadBlocked() {
        guard !isDownloadBlocked else { return }
        isDownloadBlocked = true
        loadingIndicator.stopAnimation(nil)
        loadingIndicator.isHidden = true
        errorLabel.stringValue = String(localized: .linkPreviewDownloadNotSupported)
        errorLabel.isHidden = false
        webView.alphaValue = 0
    }

    private func show(_ error: Error) {
        guard !isDownloadBlocked else { return }
        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled {
            return
        }
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
        guard !isDownloadBlocked, webView.navigationDelegate != nil else { return }

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
            guard let self, !isDownloadBlocked, webView.navigationDelegate != nil else { return }
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
        guard !isDownloadBlocked, webView.navigationDelegate != nil else { return }
        loadingIndicator.stopAnimation(nil)
        loadingIndicator.isHidden = true
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.2
            webView.animator().alphaValue = 1
        }
    }
}
