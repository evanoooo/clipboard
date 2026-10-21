//
//  Duration+Extension.swift
//  Clipboard
//

import Foundation

extension Duration {
    /// 毫秒数值，供性能日志比较使用。
    nonisolated var milliseconds: Double {
        Double(components.seconds) * 1_000
            + Double(components.attoseconds) / 1_000_000_000_000_000
    }

    /// 保留一位小数的毫秒文本，例如 `12.4ms`。
    nonisolated var millisecondsText: String {
        "\(milliseconds.formatted(.number.precision(.fractionLength(1))))ms"
    }
}
