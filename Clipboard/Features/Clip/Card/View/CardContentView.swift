//
//  CardContentView.swift
//  Clipboard
//

import AppKit
import Combine
import SnapKit

// MARK: - Lightweight Card Text View

private func makeCardTextView() -> CardAttributedTextView {
    CardAttributedTextView()
}

// MARK: - CardContentView

final class CardContentView: NSView, PassthroughMouseEvents {
    private var currentContentView: NSView?
    private var currentModel: PasteboardModel?
    private var currentKeyword: String = ""

    private var linkPreviewCancellable: AnyCancellable?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.masksToBounds = true
        observeLinkPreviewSetting()
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError()
    }

    // MARK: Configure

    func configure(with model: PasteboardModel, keyword: String = "") {
        let isSameModel = currentModel?.uniqueId == model.uniqueId
        let isSameKeyword = currentKeyword == keyword

        currentModel = model
        currentKeyword = keyword
        needsDisplay = true

        guard !isSameModel || !isSameKeyword else { return }

        if isSameModel {
            updateKeyword(keyword, in: currentContentView)
        } else {
            replaceContentView(for: model, keyword: keyword)
        }
    }

    func resetContent() {
        cancelCurrentLoad()
        currentModel = nil
        currentKeyword = ""
        if let stringView = currentContentView as? CardStringContentView {
            stringView.reset()
        } else if let richView = currentContentView as? CardRichContentView {
            richView.reset()
        } else if let imageView = currentContentView as? CardImageContentView {
            imageView.reset()
        } else {
            currentContentView?.removeFromSuperview()
            currentContentView = nil
        }
        needsDisplay = true
    }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            let color: NSColor = currentModel == nil || currentModel?.type == .color
                ? .clear : .textBackgroundColor
            layer?.backgroundColor = color.cgColor
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    // MARK: Private

    private func observeLinkPreviewSetting() {
        linkPreviewCancellable = UserDefaults.standard
            .publisher(for: \.enableLinkPreview)
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                guard let self,
                      let model = currentModel,
                      model.type == .link
                else { return }
                replaceContentView(for: model, keyword: currentKeyword)
            }
    }

    private func replaceContentView(for model: PasteboardModel, keyword: String) {
        let kind = ClipContentRenderer.resolveKind(for: model)
        if tryInPlaceReuse(for: model, kind: kind, keyword: keyword) {
            return
        }

        cancelCurrentLoad()
        currentContentView?.removeFromSuperview()
        currentContentView = nil

        let view = makeContentView(for: model, kind: kind, keyword: keyword)
        addSubview(view)
        view.snp.makeConstraints { $0.edges.equalToSuperview() }
        currentContentView = view
    }

    private func tryInPlaceReuse(for model: PasteboardModel, kind: ClipContentKind, keyword: String) -> Bool {
        guard let current = currentContentView else { return false }
        switch kind {
        case .code, .plainText:
            if let stringView = current as? CardStringContentView {
                stringView.updateKeyword(keyword, model: model)
                return true
            }
        case .richText:
            if let richView = current as? CardRichContentView {
                richView.update(with: model, keyword: keyword)
                return true
            }
        case .image:
            if let imageView = current as? CardImageContentView {
                imageView.update(with: model, keyword: keyword)
                return true
            }
        default:
            break
        }
        return false
    }

    private func updateKeyword(_ keyword: String, in view: NSView?) {
        guard let model = currentModel else { return }
        switch view {
        case let view as CardStringContentView:
            view.updateKeyword(keyword, model: model)
        case let view as CardRichContentView:
            view.updateKeyword(keyword, model: model)
        case let view as CardImageContentView:
            view.updateKeyword(keyword, model: model)
        case let view as CardLinkPreviewContentView:
            view.updateKeyword(keyword, model: model)
        default:
            break
        }
    }

    private func cancelCurrentLoad() {
        (currentContentView as? CancellableLoadable)?.cancelLoad()
    }

    private func makeContentView(for model: PasteboardModel, kind: ClipContentKind, keyword: String) -> NSView {
        switch kind {
        case .empty:
            return NSView()
        case .color:
            return CardColorContentView(model: model)
        case .image:
            return CardImageContentView(model: model, keyword: keyword)
        case .file:
            return CardFileContentView(model: model)
        case .richText:
            return CardRichContentView(model: model, keyword: keyword)
        case .code, .plainText:
            return CardStringContentView(model: model, keyword: keyword)
        case .linkPreview:
            return CardLinkPreviewContentView(model: model, keyword: keyword)
        }
    }
}

// MARK: - CardStringContentView

final class CardStringContentView: NSView, PassthroughMouseEvents {
    private lazy var textView: CardAttributedTextView = makeCardTextView()

    init(model: PasteboardModel, keyword: String) {
        super.init(frame: .zero)
        addSubview(textView)
        textView.snp.makeConstraints { $0.edges.equalToSuperview() }

        updateKeyword(keyword, model: model)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError()
    }

    func updateKeyword(_ keyword: String, model: PasteboardModel) {
        let attributed = ClipContentRenderer.resolveText(for: model, keyword: keyword, isRich: false, isCardSnippet: true)
        if model.pasteboardType == .string {
            let font: NSFont = model.detectedCodeLanguage != nil
                ? CodeTheme().monospacedFont
                : .preferredFont(forTextStyle: .body)
            let mutable = NSMutableAttributedString(attributedString: attributed)
            mutable.enumerateAttribute(.font, in: NSRange(location: 0, length: mutable.length)) { value, range, _ in
                if value == nil {
                    mutable.addAttribute(.font, value: font, range: range)
                }
            }
            textView.attributedText = mutable
        } else {
            textView.attributedText = attributed
        }
    }

    func reset() {
        textView.attributedText = NSAttributedString()
    }
}

// MARK: - CardAttributedTextView (Zero-NSTextView lightweight renderer)

private final class CardAttributedTextView: NSView {
    var attributedText = NSAttributedString() {
        didSet { needsDisplay = true }
    }

    var backgroundColor: NSColor? {
        didSet { needsDisplay = true }
    }

    override var isFlipped: Bool { true }

    override func hitTest(_: NSPoint) -> NSView? {
        nil
    }

    override func rightMouseDown(with event: NSEvent) {
        nextResponder?.rightMouseDown(with: event)
    }

    override func draw(_ dirtyRect: NSRect) {
        if let backgroundColor {
            backgroundColor.setFill()
            dirtyRect.fill()
        }
        guard attributedText.length > 0 else { return }
        let textRect = bounds.insetBy(dx: Const.space10, dy: Const.space8)
        guard textRect.width > 0, textRect.height > 0 else { return }
        attributedText.draw(with: textRect, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
    }
}

// MARK: - CardRichContentView

final class CardRichContentView: NSView, PassthroughMouseEvents {
    private lazy var textView: CardAttributedTextView = makeCardTextView()
    private var model: PasteboardModel

    init(model: PasteboardModel, keyword: String) {
        self.model = model
        super.init(frame: .zero)

        addSubview(textView)
        textView.snp.makeConstraints { $0.edges.equalToSuperview() }
        textView.attributedText = ClipContentRenderer.resolveText(for: model, keyword: keyword, isRich: true)
        updateBackground()
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError()
    }

    func updateKeyword(_ keyword: String, model: PasteboardModel) {
        textView.attributedText = ClipContentRenderer.resolveText(for: model, keyword: keyword, isRich: true)
    }

    func update(with model: PasteboardModel, keyword: String) {
        self.model = model
        textView.attributedText = ClipContentRenderer.resolveText(for: model, keyword: keyword, isRich: true)
        updateBackground()
    }

    func reset() {
        textView.attributedText = NSAttributedString()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateBackground()
    }

    private func updateBackground() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            let background = model.richBackground(on: .textBackgroundColor)
            textView.backgroundColor = background
        }
    }
}

// MARK: - CardColorContentView

final class CardColorContentView: NSView, PassthroughMouseEvents {
    private lazy var label: NSTextField = {
        let field = NSTextField(labelWithString: "")
        field.font = .systemFont(ofSize: NSFont.systemFontSize + 4, weight: .medium)
        field.alignment = .center
        field.lineBreakMode = .byTruncatingTail
        return field
    }()

    private var dynamicBgColor: NSColor = .controlBackgroundColor

    init(model: PasteboardModel) {
        super.init(frame: .zero)
        wantsLayer = true

        dynamicBgColor = model.cachedBackgroundColor ?? .controlBackgroundColor
        applyColors()

        label.stringValue = model.colorDisplayText
        addSubview(label)
        label.snp.makeConstraints { make in
            make.center.equalToSuperview()
            make.leading.greaterThanOrEqualToSuperview().offset(Const.space8)
            make.trailing.lessThanOrEqualToSuperview().offset(-Const.space8)
        }
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyColors()
    }

    private func applyColors() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = dynamicBgColor.cgColor
            label.textColor = contrastingNSColor(for: dynamicBgColor)
        }
    }
}
