//
//  FloatingLinkContentView.swift
//  Clipboard
//

import AppKit
import SnapKit

// MARK: - FloatingLinkContentView

final class FloatingLinkContentView: NSView, CancellableLoadable {
    private let iconView = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let urlLabel = NSTextField(labelWithString: "")
    private var loadTask: Task<Void, Never>?
    private let displayMode: FloatingDisplayMode

    func cancelLoad() {
        loadTask?.cancel()
        loadTask = nil
    }

    init(model: PasteboardModel, keyword: String, displayMode: FloatingDisplayMode) {
        self.displayMode = displayMode
        super.init(frame: .zero)

        iconView.imageScaling = .scaleProportionallyUpOrDown
        iconView.image = NSImage(systemSymbolName: "link", accessibilityDescription: nil)
        iconView.contentTintColor = .secondaryLabelColor
        addSubview(iconView)
        iconView.snp.makeConstraints { make in
            make.leading.equalToSuperview()
            make.centerY.equalToSuperview()
            make.width.height.equalTo(20)
        }

        let textStack = NSStackView()
        textStack.orientation = .vertical
        textStack.alignment = .leading
        textStack.spacing = 2
        addSubview(textStack)
        textStack.snp.makeConstraints { make in
            make.leading.equalTo(iconView.snp.trailing).offset(Const.space6)
            make.trailing.equalToSuperview()
            make.centerY.equalToSuperview()
        }

        titleLabel.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .medium)
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.maximumNumberOfLines = 1

        urlLabel.font = .systemFont(ofSize: NSFont.labelFontSize, weight: .regular)
        urlLabel.textColor = .secondaryLabelColor
        urlLabel.lineBreakMode = .byTruncatingMiddle
        urlLabel.maximumNumberOfLines = 1

        textStack.addArrangedSubview(titleLabel)
        textStack.addArrangedSubview(urlLabel)
        if displayMode == .minimal {
            urlLabel.isHidden = true
            titleLabel.snp.makeConstraints { $0.width.equalTo(textStack) }
        }

        let urlString = model.attributeString.string
        if keyword.isEmpty {
            urlLabel.stringValue = urlString
        } else {
            urlLabel.attributedStringValue = model.highlightedPlainText(keyword: keyword)
        }

        loadMetadata(for: model, urlString: urlString)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError()
    }

    deinit { loadTask?.cancel() }

    private func loadMetadata(for model: PasteboardModel, urlString: String) {
        if let cached = model.cachedLinkMetadata {
            applyMetadata(title: cached.title, icon: cached.iconImage ?? cached.previewImage, urlString: urlString)
        } else {
            applyMetadata(title: nil, icon: nil, urlString: urlString)
            loadTask = Task { @MainActor [weak self] in
                guard let url = URL(string: urlString) else { return }
                let metadata = await LinkMetadataService.shared.fetchMetadata(for: url)
                guard !Task.isCancelled, let self else { return }
                model.cachedLinkMetadata = metadata
                applyMetadata(title: metadata.title, icon: metadata.iconImage ?? metadata.previewImage, urlString: urlString)
            }
        }
    }

    private func applyMetadata(title: String?, icon: NSImage?, urlString: String) {
        let title = title?.trimmingCharacters(in: .whitespacesAndNewlines)
        titleLabel.stringValue = title.flatMap { $0.isEmpty ? nil : $0 }
            ?? URL(string: urlString)?.host() ?? urlString
        if displayMode == .minimal {
            toolTip = "\(titleLabel.stringValue)\n\(urlString)"
        }
        if let icon {
            iconView.image = icon
            iconView.contentTintColor = nil
        }
    }
}
