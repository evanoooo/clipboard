//
//  CardImageContentView.swift
//  Clipboard
//

import AppKit
import SnapKit

// MARK: - CardImageContentView

final class CardImageContentView: NSView, PassthroughMouseEvents, CancellableLoadable {
    private lazy var checkerboardView = CheckerboardView()
    private lazy var imageContainerView: NSView = {
        let view = NSView()
        view.wantsLayer = true
        view.layer?.masksToBounds = true
        return view
    }()

    private lazy var imageView: NSImageView = {
        let view = NSImageView()
        view.imageScaling = .scaleProportionallyUpOrDown
        view.isHidden = true
        return view
    }()

    private lazy var loadingIndicator: NSProgressIndicator = {
        let indicator = NSProgressIndicator()
        indicator.style = .spinning
        indicator.controlSize = .small
        indicator.isHidden = true
        return indicator
    }()

    private lazy var placeholderImageView: NSImageView = {
        let view = NSImageView()
        view.image = NSImage(systemSymbolName: "photo.badge.arrow.down", accessibilityDescription: nil)
        view.contentTintColor = .secondaryLabelColor
        view.imageScaling = .scaleProportionallyUpOrDown
        return view
    }()

    private var loadTask: Task<Void, Never>?
    private var currentModelId: String = ""
    private var isFillMode: Bool = false
    private var currentImageSize: CGSize?

    private let maxFillCropRatio: CGFloat = 0.15

    private static let containerSize = CGSize(width: Const.cardSize, height: Const.cntSize)
    private static let containerRatio = Const.cardSize / Const.cntSize

    init(model: PasteboardModel, keyword: String) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.masksToBounds = true
        setupViews()
        load(model: model, keyword: keyword)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError()
    }

    deinit {
        loadTask?.cancel()
    }

    func cancelLoad() {
        loadTask?.cancel()
        loadTask = nil
    }

    func updateKeyword(_ keyword: String, model: PasteboardModel) {
        // 卡片缩略图专注于极速渲染，不再执行耗时的二次实时 Vision OCR 识别
    }

    func update(with model: PasteboardModel, keyword: String = "") {
        load(model: model, keyword: keyword)
    }

    func reset() {
        cancelLoad()
        currentModelId = ""
        imageView.image = nil
        imageView.isHidden = true
        placeholderImageView.isHidden = true
        loadingIndicator.stopAnimation(nil)
        loadingIndicator.isHidden = true
    }

    private func setupViews() {
        addSubview(checkerboardView)
        addSubview(imageContainerView)
        addSubview(loadingIndicator)
        addSubview(placeholderImageView)

        imageContainerView.addSubview(imageView)

        checkerboardView.snp.makeConstraints { $0.edges.equalToSuperview() }
        imageContainerView.snp.makeConstraints { $0.edges.equalToSuperview() }
        imageView.snp.makeConstraints { $0.edges.equalToSuperview() }

        loadingIndicator.snp.makeConstraints { make in
            make.center.equalToSuperview()
        }
        placeholderImageView.snp.makeConstraints { make in
            make.center.equalToSuperview()
            make.width.height.equalTo(48)
        }
    }

    private func applyImageLayout(imageSize: CGSize) {
        let containerSize = Self.containerSize
        let imageRatio = imageSize.width / imageSize.height
        let containerRatio = containerSize.width / containerSize.height

        imageContainerView.snp.remakeConstraints { make in
            make.center.equalToSuperview()
            if isFillMode {
                if imageRatio > containerRatio {
                    make.height.equalToSuperview()
                    make.width.equalTo(imageContainerView.snp.height).multipliedBy(imageRatio)
                } else {
                    make.width.equalToSuperview()
                    make.height.equalTo(imageContainerView.snp.width).dividedBy(imageRatio)
                }
            } else {
                if imageRatio > containerRatio {
                    make.width.equalToSuperview()
                    make.height.equalTo(imageContainerView.snp.width).dividedBy(imageRatio)
                } else {
                    make.height.equalToSuperview()
                    make.width.equalTo(imageContainerView.snp.height).multipliedBy(imageRatio)
                }
            }
        }
    }

    private func load(model: PasteboardModel, keyword: String) {
        guard currentModelId != model.uniqueId else {
            return
        }

        loadTask?.cancel()
        currentModelId = model.uniqueId

        // 缓存极速快查：若缩略图已就绪，立即同步装配，0 延迟、0 闪烁
        if let image = model.cachedThumbnail {
            loadingIndicator.stopAnimation(nil)
            loadingIndicator.isHidden = true
            placeholderImageView.isHidden = true

            isFillMode = shouldUseFillMode(for: image.size)
            currentImageSize = image.size

            imageView.imageScaling = .scaleProportionallyUpOrDown
            imageView.image = image
            imageView.isHidden = false
            applyImageLayout(imageSize: image.size)
            return
        }

        imageView.isHidden = true
        placeholderImageView.isHidden = true
        loadingIndicator.isHidden = false
        loadingIndicator.startAnimation(nil)

        loadTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let image = await model.loadThumbnail()
            guard !Task.isCancelled else { return }

            loadingIndicator.stopAnimation(nil)
            loadingIndicator.isHidden = true

            if let image {
                isFillMode = shouldUseFillMode(for: image.size)
                currentImageSize = image.size

                imageView.imageScaling = .scaleProportionallyUpOrDown
                imageView.image = image
                imageView.isHidden = false
                applyImageLayout(imageSize: image.size)
            } else {
                placeholderImageView.isHidden = false
            }
        }
    }

    private func shouldUseFillMode(for imageSize: CGSize) -> Bool {
        guard imageSize.width > 0, imageSize.height > 0 else { return false }

        let fillLayout = imageLayout(
            imageSize: imageSize,
            containerSize: Self.containerSize,
            isFillMode: true
        )
        let fillArea = fillLayout.width * fillLayout.height
        let visibleArea = Self.containerSize.width * Self.containerSize.height

        guard fillArea > 0 else { return false }

        let cropRatio = max(0, 1 - (visibleArea / fillArea))
        return cropRatio <= maxFillCropRatio
    }
}

private func imageLayout(imageSize: CGSize, containerSize: CGSize, isFillMode: Bool) -> CGRect {
    let imageRatio = imageSize.width / imageSize.height
    let containerRatio = containerSize.width / containerSize.height

    let renderSize: CGSize
    if isFillMode {
        if imageRatio > containerRatio {
            let height = containerSize.height
            renderSize = CGSize(width: height * imageRatio, height: height)
        } else {
            let width = containerSize.width
            renderSize = CGSize(width: width, height: width / imageRatio)
        }
    } else {
        if imageRatio > containerRatio {
            let width = containerSize.width
            renderSize = CGSize(width: width, height: width / imageRatio)
        } else {
            let height = containerSize.height
            renderSize = CGSize(width: height * imageRatio, height: height)
        }
    }

    let left = (containerSize.width - renderSize.width) / 2
    let top = (containerSize.height - renderSize.height) / 2
    return CGRect(origin: CGPoint(x: left, y: top), size: renderSize)
}
