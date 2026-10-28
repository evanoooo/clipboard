//
//  CheckerboardView.swift
//  Clipboard
//

import AppKit

// MARK: - CheckerboardView

final class CheckerboardView: NSView {
    private static let tileSize: CGFloat = 16 // 2×2 格，每格 8pt

    private static let lightPatternColor: NSColor? = makePatternColor(
        light: Const.lightImageShallowColor,
        dark: Const.lightImageDeepColor
    )
    private static let darkPatternColor: NSColor? = makePatternColor(
        light: Const.darkImageShallowColor,
        dark: Const.darkImageDeepColor
    )

    override init(frame: NSRect) {
        super.init(frame: frame)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError()
    }

    override func draw(_ dirtyRect: NSRect) {
        let isDark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let pattern = (isDark ? Self.darkPatternColor : Self.lightPatternColor) ?? .clear
        pattern.setFill()
        dirtyRect.fill()
    }

    // MARK: - Private

    private static func makePatternColor(light: NSColor, dark: NSColor) -> NSColor? {
        let size = Int(tileSize)
        let half = size / 2
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: nil,
            width: size, height: size,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        ctx.setFillColor(light.cgColor)
        ctx.fill([CGRect(x: 0, y: 0, width: half, height: half),
                  CGRect(x: half, y: half, width: half, height: half)])

        ctx.setFillColor(dark.cgColor)
        ctx.fill([CGRect(x: half, y: 0, width: half, height: half),
                  CGRect(x: 0, y: half, width: half, height: half)])

        guard let image = ctx.makeImage() else { return nil }
        let nsImage = NSImage(cgImage: image, size: NSSize(width: tileSize, height: tileSize))
        return NSColor(patternImage: nsImage)
    }
}
