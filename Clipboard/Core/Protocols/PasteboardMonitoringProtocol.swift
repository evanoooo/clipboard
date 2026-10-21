//
//  PasteboardMonitoringProtocol.swift
//  Clipboard
//
//  Created on 2026/10/21.
//

import Foundation

/// 系统剪贴板监听与生命周期协议
protocol PasteboardMonitoringProtocol: AnyObject {
    /// 当前是否处于暂停监听状态
    var isPaused: Bool { get }

    /// 暂停开始的时间戳
    var pausedAt: Date? { get }

    /// 开启剪贴板变化监听轮询
    func startListening()

    /// 停止剪贴板变化监听轮询
    func stopListening()

    /// 暂停监听指定时长（秒），nil 表示无限期暂停
    func pause(for duration: TimeInterval?)

    /// 恢复监听
    func resume()
}
