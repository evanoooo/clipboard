//
//  CardHeadView.swift
//  Clipboard
//
//

import AppKit
import Combine
import SnapKit

final class CardHeadView: NSView {
    private var iconLoadTask: Task<Void, Never>?
    private var colorSubscription: AnyCancellable?
    private weak var model: PasteboardModel?
    private(set) var isEditingAlias = false

    /// 提交别名（空串表示清除）。由外层负责持久化。
    var onAliasCommit: ((String) -> Void)?
    /// 进入/退出别名编辑，外层据此切换键盘焦点区域。
    var onAliasEditingChanged: ((Bool) -> Void)?

    // MARK: - Subviews

    private lazy var backgroundView: NSView = {
        let view = NSView()
        view.wantsLayer = true
        return view
    }()

    /// 标题行：有别名时显示别名，否则显示内容类型；点击进入别名编辑。
    private lazy var titleField: NSTextField = {
        let field = NSTextField(labelWithString: "")
        field.textColor = .white
        field.font = .systemFont(ofSize: NSFont.systemFontSize + 2)
        field.lineBreakMode = .byTruncatingTail
        field.maximumNumberOfLines = 1
        field.focusRingType = .none
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return field
    }()

    /// 副标题行：默认分组显示时间。一旦有别名或在自定义分类下，不再出现干瘪的类型文字。
    private lazy var subtitleField: NSTextField = {
        let field = NSTextField(labelWithString: "")
        field.font = .systemFont(ofSize: NSFont.systemFontSize)
        field.textColor = NSColor.white.withAlphaComponent(0.85)
        field.lineBreakMode = .byTruncatingTail
        return field
    }()

    private lazy var textStack: NSStackView = {
        let stack = NSStackView(views: [titleField, subtitleField])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 2
        stack.distribution = .fill
        return stack
    }()

    private lazy var iconView: NSImageView = {
        let view = NSImageView()
        view.imageScaling = .scaleProportionallyUpOrDown
        view.isHidden = false
        return view
    }()

    // MARK: - Init

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    // MARK: - Configure

    func configure(with model: PasteboardModel) {
        self.model = model

        let color = AppColorService.shared.color(for: model)
        backgroundView.layer?.backgroundColor = color.cgColor
        colorSubscription = AppColorService.shared.changes.sink { [weak self, weak model] name in
            guard let self, let model, model.appName == name else { return }
            backgroundView.layer?.backgroundColor = AppColorService.shared.color(for: model).cgColor
        }

        if !isEditingAlias {
            applyDisplay(alias: model.alias)
        }

        // 置顶/分类到标签后仍保留来源应用图标，与默认分组、悬浮窗、预览保持一致
        iconView.isHidden = false
        iconView.image = AppIconCache.shared.getCachedIcon(forAppID: model.appID, path: model.appPath)
        iconLoadTask?.cancel()
        iconLoadTask = Task { @MainActor [weak self] in
            let icon = await AppIconCache.shared.loadIcon(forAppID: model.appID, path: model.appPath)
            guard !Task.isCancelled else { return }
            self?.iconView.image = icon
        }
    }

    func reset() {
        // 卡片复用时提交已输入的内容，避免滚动导致编辑丢失。
        finishAliasEditing(commit: true)
        colorSubscription = nil
        iconLoadTask?.cancel()
        iconLoadTask = nil
        iconView.image = nil
        model = nil
        titleField.stringValue = ""
        subtitleField.stringValue = ""
        subtitleField.isHidden = false
        backgroundView.layer?.backgroundColor = nil
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        guard let model else { return }
        let color = AppColorService.shared.color(for: model)
        backgroundView.layer?.backgroundColor = color.cgColor
    }

    func refreshTimestamp(for model: PasteboardModel) {
        guard !isEditingAlias else { return }
        applyDisplay(alias: model.alias)
    }

    // MARK: - Alias Editing

    func beginAliasEditing() {
        guard let model, !isEditingAlias else { return }
        isEditingAlias = true

        titleField.isEditable = true
        titleField.isSelectable = true
        titleField.cell?.isScrollable = true
        // 首次重命名同样预填当前标题（类型名），而不是用占位符，两次行为一致。
        titleField.stringValue = model.alias.isEmpty ? model.type.string : model.alias

        onAliasEditingChanged?(true)

        guard window != nil else { return }
        // 菜单项唤起时，菜单关闭可能重置 first responder，延后一拍再聚焦。
        Task { @MainActor [weak self] in
            guard let self, isEditingAlias, let window else { return }
            window.makeFirstResponder(titleField)
            titleField.currentEditor()?.selectAll(nil)
        }
    }

    private func finishAliasEditing(commit: Bool) {
        guard isEditingAlias else { return }
        isEditingAlias = false

        let trimmed = titleField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        // 提交值与类型名相同（未做任何修改）时视为没有命名，不写入别名。
        let effective = trimmed == model?.type.string ? "" : trimmed
        titleField.isEditable = false
        titleField.isSelectable = false
        titleField.cell?.isScrollable = false

        if commit {
            applyDisplay(alias: effective)
            onAliasCommit?(effective)
        } else {
            applyDisplay(alias: model?.alias ?? "")
        }

        onAliasEditingChanged?(false)
    }

    private func applyDisplay(alias: String) {
        guard let model else { return }
        let type = model.detectedCodeLanguage?.displayName ?? model.type.string
        let hasAlias = !alias.isEmpty
        let isDefault = model.group == -1
        let time = model.timestamp.timeAgo(relativeTo: TimeManager.shared.currentTime)

        titleField.stringValue = hasAlias ? alias : type
        titleField.toolTip = hasAlias ? alias : String(localized: .rename)

        switch (isDefault, hasAlias) {
        case (true, true):
            // 默认分组 + 有别名：副标题清晰展示时间，类型转由底部图标承载
            subtitleField.isHidden = false
            subtitleField.stringValue = time
        case (true, false):
            // 默认分组 + 无别名：主标题为类型名，副标题展示时间
            subtitleField.isHidden = false
            subtitleField.stringValue = time
        case (false, true):
            // 自定义分组 + 有别名：主标题单行聚焦别名，隐藏冗余的纯类型文本
            subtitleField.isHidden = true
            subtitleField.stringValue = ""
        case (false, false):
            // 自定义分组 + 无别名：主标题展示类型名，副标题隐藏
            subtitleField.isHidden = true
            subtitleField.stringValue = ""
        }
    }
}

// MARK: - NSTextFieldDelegate

extension CardHeadView: NSTextFieldDelegate {
    func control(
        _: NSControl,
        textView _: NSTextView,
        doCommandBy commandSelector: Selector
    ) -> Bool {
        switch commandSelector {
        case #selector(NSResponder.insertNewline(_:)):
            finishAliasEditing(commit: true)
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            finishAliasEditing(commit: false)
            return true
        default:
            return false
        }
    }

    func controlTextDidEndEditing(_: Notification) {
        finishAliasEditing(commit: true)
    }
}

// MARK: - Private

private extension CardHeadView {
    func setup() {
        wantsLayer = true
        layer?.masksToBounds = true
        layer?.backgroundColor = .clear

        titleField.delegate = self

        let click = NSClickGestureRecognizer(target: self, action: #selector(handleTitleClick))
        click.delaysPrimaryMouseButtonEvents = false
        textStack.addGestureRecognizer(click)

        addSubview(backgroundView)
        backgroundView.addSubview(textStack)
        backgroundView.addSubview(iconView)

        backgroundView.snp.makeConstraints { make in
            make.edges.equalToSuperview()
        }

        iconView.snp.makeConstraints { make in
            make.trailing.equalToSuperview().offset(15)
            make.centerY.equalToSuperview()
            make.width.height.equalTo(Const.iconSize)
        }

        textStack.snp.makeConstraints { make in
            make.leading.equalToSuperview().offset(Const.space10)
            make.trailing.lessThanOrEqualTo(iconView.snp.leading).offset(-Const.space8)
            make.centerY.equalToSuperview()
        }
    }

    @objc func handleTitleClick() {
        beginAliasEditing()
    }
}
