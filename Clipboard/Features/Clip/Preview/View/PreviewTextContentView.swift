//
//  PreviewTextContentView.swift
//  Clipboard
//
//  纯文本及富文本预览。
//

import AppKit
import SnapKit

final class PreviewTextContentView: NSView {
    private let scrollView = NSScrollView()
    private let textView = NSTextView()
    private let model: PasteboardModel

    init(model: PasteboardModel) {
        self.model = model
        super.init(frame: .zero)
        wantsLayer = true

        setupScrollView()
        setupTextView()

        scrollView.documentView = textView
        addSubview(scrollView)
        scrollView.snp.makeConstraints { $0.edges.equalToSuperview() }

        applyContent(for: model)
        updateBackground()
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateBackground()
    }

    private func updateBackground() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            let background = model.type == .rich
                ? model.richBackground(on: .textBackgroundColor, forPreview: true)
                : nil
            textView.backgroundColor = background ?? .textBackgroundColor
            layer?.backgroundColor = textView.backgroundColor.cgColor
        }
    }

    override func layout() {
        super.layout()
        let contentWidth = scrollView.contentSize.width
        guard contentWidth > 0 else { return }
        if textView.frame.width != contentWidth {
            textView.frame = NSRect(
                x: 0,
                y: 0,
                width: contentWidth,
                height: max(scrollView.contentSize.height, 1)
            )
            textView.minSize = NSSize(width: 0, height: scrollView.contentSize.height)
            textView.maxSize = NSSize(width: contentWidth, height: .greatestFiniteMagnitude)
            textView.textContainer?.containerSize = NSSize(
                width: contentWidth,
                height: .greatestFiniteMagnitude
            )
        }
    }

    private func setupScrollView() {
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false
    }

    private func setupTextView() {
        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = true
        textView.textContainerInset = NSSize(width: Const.space8, height: Const.space8)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = .width
        textView.textContainer?.widthTracksTextView = true
        textView.layoutManager?.allowsNonContiguousLayout = true
    }

    private func applyContent(for model: PasteboardModel) {
        switch model.type {
        case .rich:
            applyRichContent(for: model)
        default:
            applyPlainContent(for: model)
        }
    }

    private func applyRichContent(for model: PasteboardModel) {
        let base = NSAttributedString(with: model.data, type: model.pasteboardType)
            ?? model.attributeString

        if model.hasBgColor {
            textView.textStorage?.setAttributedString(base)
        } else {
            let mutable = NSMutableAttributedString(attributedString: base)
            mutable.addAttribute(
                .foregroundColor,
                value: NSColor.labelColor,
                range: NSRange(location: 0, length: mutable.length)
            )
            textView.textStorage?.setAttributedString(mutable)
        }
        if let content = textView.textStorage {
            model.cachePreviewColors(content)
        }
    }

    private func applyPlainContent(for model: PasteboardModel) {
        let source = String(data: model.data, encoding: .utf8)
            ?? model.attributeString.string

        if let language = model.detectedCodeLanguage {
            // 代码/配置语言：调度 CodeHighlighter 应用语法高亮并确保等宽空格与制表符对齐
            let theme = CodeTheme(fontSize: NSFont.systemFontSize)
            let attributed = CodeHighlighter.highlight(source, language: language, theme: theme)

            let mutable = NSMutableAttributedString(attributedString: attributed)
            let charWidth = (" " as NSString).size(withAttributes: [.font: theme.monospacedFont]).width
            let paragraphStyle = NSMutableParagraphStyle()
            paragraphStyle.defaultTabInterval = max(charWidth * 4, 28)
            paragraphStyle.tabStops = []
            mutable.addAttribute(.paragraphStyle, value: paragraphStyle, range: NSRange(location: 0, length: mutable.length))

            textView.textStorage?.setAttributedString(mutable)
        } else {
            textView.font = .systemFont(ofSize: NSFont.systemFontSize)
            textView.textColor = .labelColor
            textView.string = source
        }
    }
}
