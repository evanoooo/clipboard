//
//  PreviewWebView.swift
//  Clipboard
//
//  链接网页预览。
//

import AppKit
import SnapKit
import WebKit

final class PreviewWebView: NSView, WKNavigationDelegate, PreviewResettable {
    private let webView: WKWebView
    private let loadingIndicator: NSProgressIndicator
    private let errorLabel: NSTextField
    private let url: URL

    init(url: URL) {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        webView = WKWebView(frame: .zero, configuration: configuration)
        loadingIndicator = NSProgressIndicator()
        errorLabel = NSTextField(wrappingLabelWithString: "")
        self.url = url
        super.init(frame: .zero)
        wantsLayer = true

        webView.navigationDelegate = self
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

    private func show(_ error: Error) {
        let nsError = error as NSError
        log.error(
            "[linkPreview] 加载失败 url=\(url.absoluteString) "
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
                "[linkPreview] 加载完成 url=\(url.absoluteString) title=\(title) "
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
