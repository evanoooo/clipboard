//
//  ChipScrollView.swift
//  Clipboard
//
//  Created by crown on 2026/4/9.
//

import AppKit
import SnapKit

final class ChipScrollView: NSView {
    // MARK: - Drag & Reorder State

    private struct DragState {
        let draggedButton: ChipButton
        let fromIndex: Int
        var targetIndex: Int
        let initialFrames: [NSRect]
    }

    private var activeDragState: DragState?
    private var isReordering: Bool = false

    // MARK: - Properties

    private let scrollView = HorizontalScrollView()
    private let contentStack = NSStackView()

    private var chips: [CategoryChip] = []
    private var chipButtons: [ChipButton] = []
    private weak var newChipButton: ChipButton?
    private var pendingScrollOrigin: NSPoint?

    var modeButtons: [Int: ChipButton] {
        Dictionary(uniqueKeysWithValues: zip(chips.map(\.id), chipButtons))
    }

    var selectedChipId: Int = -1 {
        didSet {
            guard oldValue != selectedChipId else { return }
            syncSelection()
        }
    }

    var onSelectionChanged: ((Int) -> Void)?

    var scrollMode: Bool = false

    var maximumWidth: CGFloat = .greatestFiniteMagnitude {
        didSet {
            guard oldValue != maximumWidth else { return }
            invalidateWidth()
        }
    }

    // MARK: - Init

    override init(frame: NSRect) {
        super.init(frame: frame)
        setup()
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError()
    }

    // MARK: - Setup

    private func setup() {
        wantsLayer = true

        scrollView.drawsBackground = false
        scrollView.hasHorizontalScroller = false
        scrollView.hasVerticalScroller = false
        scrollView.horizontalScrollElasticity = .allowed
        scrollView.verticalScrollElasticity = .none

        let clipView = NSClipView()
        clipView.drawsBackground = false
        scrollView.contentView = clipView

        contentStack.orientation = .horizontal
        contentStack.spacing = Const.space6 / 2
        contentStack.alignment = .centerY
        scrollView.documentView = contentStack

        contentStack.snp.makeConstraints { make in
            make.top.bottom.leading.equalTo(clipView)
        }

        addSubview(scrollView)
        scrollView.snp.makeConstraints { make in
            make.edges.equalToSuperview()
        }
    }

    // MARK: - Intrinsic Content Size

    override var intrinsicContentSize: NSSize {
        if scrollMode {
            return NSSize(width: NSView.noIntrinsicMetric, height: NSView.noIntrinsicMetric)
        }
        return NSSize(
            width: min(contentStack.fittingSize.width, maximumWidth),
            height: NSView.noIntrinsicMetric
        )
    }

    private func invalidateWidth() {
        invalidateIntrinsicContentSize()
        needsLayout = true
        superview?.needsLayout = true
    }

    override func layout() {
        super.layout()
        if let origin = pendingScrollOrigin {
            pendingScrollOrigin = nil
            contentStack.scroll(origin)
        }
    }

    private func keepEditingEdgeVisible(_ button: ChipButton) {
        invalidateWidth()
        Task { @MainActor [weak self, weak button] in
            guard let self, let button else { return }
            guard let contentView = window?.contentView else { return }
            contentView.layoutSubtreeIfNeeded()
            let edge = NSRect(
                x: max(button.bounds.maxX - 1, 0),
                y: button.bounds.minY,
                width: 1,
                height: button.bounds.height
            )
            button.scrollToVisible(edge)
        }
    }

    // MARK: - Public API

    func reload(
        chips: [CategoryChip],
        selectedId: Int,
        dotMode: Bool = false,
        compact: Bool = false,
        creatingChip: Bool = false,
        makeConfig: ((CategoryChip, Bool, Bool) -> ChipButton.Config)? = nil
    ) {
        let oldButtons = Dictionary(uniqueKeysWithValues: zip(self.chips.map(\.id), chipButtons))
        let changed = self.chips.map(\.id) != chips.map(\.id)
        let hadPlaceholder = newChipButton != nil
        let animate = !isReordering && !self.chips.isEmpty
            && ((changed && !hadPlaceholder) || (hadPlaceholder && !changed && !creatingChip))

        animateChanges(animate) { animated in
            pendingScrollOrigin = pendingScrollOrigin ?? scrollView.contentView.bounds.origin
            if let placeholder = newChipButton, !creatingChip {
                removeButton(placeholder, animated: animated)
                newChipButton = nil
            }
            let ids = Set(chips.map(\.id))
            for (id, button) in oldButtons where !ids.contains(id) {
                removeButton(button, animated: animated)
            }
            self.chips = chips
            chipButtons = []
            for (index, chip) in chips.enumerated() {
                let config = makeConfig?(chip, chip.id == selectedId, dotMode)
                    ?? .init(
                        chip: chip,
                        isSelected: chip.id == selectedId,
                        dotMode: dotMode,
                        compact: compact,
                        action: { [weak self] in self?.select(id: chip.id) }
                    )
                let button: ChipButton
                if let existing = oldButtons[chip.id] {
                    button = existing
                    button.update(config: config)
                } else {
                    button = makeButton(config: config)
                    insertButton(button, at: index, animated: animated)
                }
                button.isReorderable = !dotMode && !creatingChip
                if contentStack.arrangedSubviews.firstIndex(of: button) != index {
                    contentStack.removeArrangedSubview(button)
                    contentStack.insertArrangedSubview(button, at: index)
                }
                chipButtons.append(button)
                if config.isEditing {
                    keepEditingEdgeVisible(button)
                }
            }
            selectedChipId = selectedId
        }
    }

    // MARK: - Private

    private func select(id: Int) {
        selectedChipId = id
        onSelectionChanged?(id)
    }

    private func syncSelection() {
        for (btn, chip) in zip(chipButtons, chips) {
            btn.isSelected = chip.id == selectedChipId
        }
    }

    // MARK: - New Chip Placeholder

    func appendNewChipButton(config: ChipButton.Config) {
        if let button = newChipButton {
            button.update(config: config)
            return
        }
        animateChanges(!chips.isEmpty) { animated in
            let button = makeButton(config: config)
            button.isReorderable = false
            newChipButton = button
            insertButton(button, at: contentStack.arrangedSubviews.count, animated: animated)
            keepEditingEdgeVisible(button)
        }
    }

    func removeNewChipButton() {
        guard let button = newChipButton else { return }
        animateChanges(true) { animated in
            newChipButton = nil
            removeButton(button, animated: animated)
        }
    }

    // MARK: - Scroll To Visible

    func scrollToChip(id: Int) {
        guard scrollMode,
              let index = chips.firstIndex(where: { $0.id == id }),
              index < chipButtons.count
        else { return }
        let btn = chipButtons[index]
        Task { @MainActor in btn.scrollToVisible(btn.bounds) }
    }

    func scrollToEnd() {
        guard scrollMode else { return }
        let target = (newChipButton ?? chipButtons.last)
        guard let target else { return }
        Task { @MainActor in target.scrollToVisible(target.bounds) }
    }
}

// MARK: - Drag to Reorder

private extension ChipScrollView {
    func handleReorderDragBegan(_ button: ChipButton) {
        contentStack.layoutSubtreeIfNeeded()

        guard let fromIndex = chipButtons.firstIndex(of: button) else { return }
        let systemCount = CategoryChip.systemChips.count
        guard fromIndex >= systemCount else { return }
        guard chipButtons.count > systemCount + 1 else { return }

        let initialFrames = chipButtons.map { $0.frame }
        activeDragState = DragState(
            draggedButton: button,
            fromIndex: fromIndex,
            targetIndex: fromIndex,
            initialFrames: initialFrames
        )
        isReordering = true

        button.wantsLayer = true
        button.layer?.zPosition = 100
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.15
            context.allowsImplicitAnimation = true
            button.layer?.shadowColor = NSColor.black.cgColor
            button.layer?.shadowOpacity = 0.22
            button.layer?.shadowOffset = CGSize(width: 0, height: -2)
            button.layer?.shadowRadius = 4
        }
        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .default)
    }

    func handleReorderDragged(_ button: ChipButton, translationX: CGFloat) {
        guard var state = activeDragState, state.draggedButton === button else { return }

        button.layer?.transform = CATransform3DMakeTranslation(translationX, 0, 0)

        let currentCenterX = state.initialFrames[state.fromIndex].midX + translationX
        let systemCount = CategoryChip.systemChips.count
        let minSlot = systemCount
        let maxSlot = chipButtons.count - 1
        guard minSlot <= maxSlot else { return }

        var candidate = state.fromIndex
        if translationX > 0 {
            for k in (state.fromIndex + 1)...maxSlot {
                if currentCenterX > state.initialFrames[k].midX {
                    candidate = k
                }
            }
        } else if translationX < 0 {
            for k in stride(from: state.fromIndex - 1, through: minSlot, by: -1) {
                if currentCenterX < state.initialFrames[k].midX {
                    candidate = k
                }
            }
        }
        let targetIndex = min(max(candidate, minSlot), maxSlot)

        if targetIndex != state.targetIndex {
            state.targetIndex = targetIndex
            activeDragState = state
            NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .default)

            let draggedWidth = state.initialFrames[state.fromIndex].width + contentStack.spacing
            for (j, btn) in chipButtons.enumerated() where j != state.fromIndex {
                var targetShiftX: CGFloat = 0
                if targetIndex > state.fromIndex {
                    if j > state.fromIndex && j <= targetIndex {
                        targetShiftX = -draggedWidth
                    }
                } else if targetIndex < state.fromIndex {
                    if j >= targetIndex && j < state.fromIndex {
                        targetShiftX = draggedWidth
                    }
                }
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = 0.2
                    context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                    context.allowsImplicitAnimation = true
                    btn.layer?.transform = CATransform3DMakeTranslation(targetShiftX, 0, 0)
                }
            }
        }

        if scrollMode {
            let visibleRect = scrollView.contentView.bounds
            let buttonOriginInScroll = scrollView.convert(button.frame.origin, from: contentStack)
            let currentX = buttonOriginInScroll.x + translationX
            let leftMargin: CGFloat = 20
            let rightMargin: CGFloat = visibleRect.width - button.bounds.width - 20

            if currentX < leftMargin && visibleRect.minX > 0 {
                let newOrigin = NSPoint(x: max(0, visibleRect.minX - 8), y: 0)
                contentStack.scroll(newOrigin)
            } else if currentX > rightMargin {
                let maxScroll = max(0, contentStack.bounds.width - visibleRect.width)
                if visibleRect.minX < maxScroll {
                    let newOrigin = NSPoint(x: min(maxScroll, visibleRect.minX + 8), y: 0)
                    contentStack.scroll(newOrigin)
                }
            }
        }
    }

    func handleReorderDragEnded(_ button: ChipButton) {
        guard let state = activeDragState, state.draggedButton === button else { return }
        activeDragState = nil

        let fromIndex = state.fromIndex
        let targetIndex = state.targetIndex

        let finalTranslationX: CGFloat
        if targetIndex == fromIndex {
            finalTranslationX = 0
        } else if targetIndex > fromIndex {
            finalTranslationX = state.initialFrames[targetIndex].maxX - state.initialFrames[fromIndex].maxX
        } else {
            finalTranslationX = state.initialFrames[targetIndex].minX - state.initialFrames[fromIndex].minX
        }

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.18
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            context.allowsImplicitAnimation = true
            button.layer?.transform = CATransform3DMakeTranslation(finalTranslationX, 0, 0)
            button.layer?.shadowOpacity = 0
        } completionHandler: { [weak self] in
            guard let self else { return }
            button.layer?.transform = CATransform3DIdentity
            button.layer?.zPosition = 0
            for btn in self.chipButtons {
                btn.layer?.transform = CATransform3DIdentity
            }
            if targetIndex != fromIndex {
                _ = CategoryChipStore.shared.moveUserChip(fromIndex: fromIndex, toIndex: targetIndex)
            }
            Task { @MainActor [weak self] in
                self?.isReordering = false
            }
        }
    }

    func handleReorderDragCancelled(_ button: ChipButton) {
        guard let state = activeDragState, state.draggedButton === button else { return }
        activeDragState = nil

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.18
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            context.allowsImplicitAnimation = true
            button.layer?.transform = CATransform3DIdentity
            button.layer?.shadowOpacity = 0
            for btn in self.chipButtons {
                btn.layer?.transform = CATransform3DIdentity
            }
        } completionHandler: { [weak self] in
            Task { @MainActor [weak self] in
                button.layer?.zPosition = 0
                self?.isReordering = false
            }
        }
    }
}

private extension ChipScrollView {
    func makeButton(config: ChipButton.Config) -> ChipButton {
        let button = ChipButton(config: config)
        button.onWidthChanged = { [weak self, weak button] in
            guard let button else { return }
            self?.keepEditingEdgeVisible(button)
        }
        button.onReorderDragBegan = { [weak self] button in
            self?.handleReorderDragBegan(button)
        }
        button.onReorderDragged = { [weak self] button, translationX in
            self?.handleReorderDragged(button, translationX: translationX)
        }
        button.onReorderDragEnded = { [weak self] button in
            self?.handleReorderDragEnded(button)
        }
        button.onReorderDragCancelled = { [weak self] button in
            self?.handleReorderDragCancelled(button)
        }
        return button
    }

    func animateChanges(_ requested: Bool, changes: (Bool) -> Void) {
        guard requested, let window, window.isVisible, !isHiddenOrHasHiddenAncestor,
              !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
              let root = window.contentView
        else {
            changes(false)
            invalidateWidth()
            return
        }
        root.layoutSubtreeIfNeeded()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.18
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            context.allowsImplicitAnimation = true
            changes(true)
            invalidateWidth()
            root.layoutSubtreeIfNeeded()
        }
    }

    func insertButton(_ button: ChipButton, at index: Int, animated: Bool) {
        button.frame = NSRect(
            origin: NSPoint(x: contentStack.arrangedSubviews.last?.frame.maxX ?? 0, y: 0),
            size: button.fittingSize
        )
        contentStack.insertArrangedSubview(button, at: index)
        if animated {
            button.alphaValue = 0
            button.animator().alphaValue = 1
        }
    }

    func removeButton(_ button: ChipButton, animated: Bool) {
        contentStack.removeArrangedSubview(button)
        guard animated else {
            button.removeFromSuperview()
            return
        }
        // Keep the outgoing view outside the stack's layout until its fade completes.
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.18
            button.animator().alphaValue = 0
        } completionHandler: {
            Task { @MainActor in
                button.removeFromSuperview()
            }
        }
    }
}
