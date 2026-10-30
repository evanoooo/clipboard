//
//  FloatingAppIconView.swift
//  Clipboard
//

import AppKit
import SnapKit

// MARK: - FloatingAppIconView

final class FloatingAppIconView: NSView {
    private let imageView = NSImageView()
    private var loadTask: Task<Void, Never>?

    override init(frame: NSRect) {
        super.init(frame: frame)
        imageView.imageScaling = .scaleProportionallyUpOrDown
        addSubview(imageView)
        imageView.snp.makeConstraints { $0.edges.equalToSuperview() }
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError()
    }

    deinit { loadTask?.cancel() }

    func configure(appID: Int64?, appPath: String) {
        loadTask?.cancel()
        let cached = AppIconCache.shared.getCachedIcon(forAppID: appID, path: appPath)
        imageView.image = cached
        if cached == nil {
            loadTask = Task { @MainActor [weak self] in
                let icon = await AppIconCache.shared.loadIcon(forAppID: appID, path: appPath)
                guard !Task.isCancelled else { return }
                self?.imageView.image = icon
            }
        }
    }
}
