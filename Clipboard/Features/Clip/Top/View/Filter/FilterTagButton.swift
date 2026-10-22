//
//  FilterTagButton.swift
//  Clipboard
//
//  标签筛选按钮：左边颜色圆点 + 右边文案
//

import AppKit
import SnapKit

final class FilterTagButton: FilterButton {
    let groupId: Int

    init(colorIndex: Int, title: String, groupId: Int) {
        self.groupId = groupId
        super.init(icon: nil, title: title)
        setupDot(color: CategoryChip.nsColor(at: colorIndex))
    }

    init(color: NSColor, title: String, groupId: Int) {
        self.groupId = groupId
        super.init(icon: nil, title: title)
        setupDot(color: color)
    }

    private func setupDot(color: NSColor) {
        let dotContainer = NSView()
        dotContainer.snp.makeConstraints { make in
            make.width.height.equalTo(20)
        }

        let dotView = NSView()
        CategoryDotRenderer.configure(dotView, color: color)
        dotContainer.addSubview(dotView)
        dotView.snp.makeConstraints { make in
            make.width.height.equalTo(CategoryDotRenderer.diameter)
            make.center.equalToSuperview()
        }

        stack.insertArrangedSubview(dotContainer, at: 0)
    }
}
