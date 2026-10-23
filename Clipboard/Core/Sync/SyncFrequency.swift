//
//  SyncFrequency.swift
//  Clipboard
//
//  Created by crown on 2026/10/23.
//

import Foundation

enum SyncFrequency: Int, CaseIterable, Identifiable, Sendable {
    case off = 0
    case realtime = 15
    case minutes5 = 300
    case minutes15 = 900
    case minutes30 = 1800
    case hour1 = 3600
    case hours3 = 10800
    case hours6 = 21600

    var id: Int { rawValue }

    static let userDefaultsKey = "sync_frequency_seconds"

    var title: String {
        switch self {
        case .off:
            return String(localized: "关闭 (仅手动)")
        case .realtime:
            return String(localized: "实时变动 (15 秒防抖)")
        case .minutes5:
            return String(localized: "每 5 分钟")
        case .minutes15:
            return String(localized: "每 15 分钟")
        case .minutes30:
            return String(localized: "每 30 分钟")
        case .hour1:
            return String(localized: "每 1 小时")
        case .hours3:
            return String(localized: "每 3 小时")
        case .hours6:
            return String(localized: "每 6 小时")
        }
    }

    var subtitle: String {
        switch self {
        case .off:
            return String(localized: "已暂停后台自动增量同步，仅在手动点击「立即同步」时执行。")
        case .realtime:
            return String(localized: "本地内容产生变化 15 秒后，自动聚合为一次轻量增量加密上传，低能耗低流量。")
        case .minutes5:
            return String(localized: "每隔 5 分钟检查并同步一次云端与本地的增量变动。")
        case .minutes15:
            return String(localized: "每隔 15 分钟检查并同步一次云端与本地的增量变动，兼顾时效与能耗。")
        case .minutes30:
            return String(localized: "每隔 30 分钟检查并同步一次云端与本地的增量变动。")
        case .hour1:
            return String(localized: "每隔 1 小时检查并同步一次增量数据，适合低频备份。")
        case .hours3:
            return String(localized: "每隔 3 小时检查并同步一次增量数据，极低能耗。")
        case .hours6:
            return String(localized: "每隔 6 小时检查并同步一次增量数据，最低网络与能耗开销。")
        }
    }

    static var current: SyncFrequency {
        if UserDefaults.standard.object(forKey: userDefaultsKey) == nil {
            if UserDefaults.standard.object(forKey: "sync_auto_enabled") != nil {
                let legacyAuto = UserDefaults.standard.bool(forKey: "sync_auto_enabled")
                return legacyAuto ? .realtime : .off
            }
            return .realtime
        }
        let raw = UserDefaults.standard.integer(forKey: userDefaultsKey)
        return SyncFrequency(rawValue: raw) ?? .realtime
    }
}
