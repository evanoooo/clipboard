//
//  SystemEnergyMonitor.swift
//  Clipboard
//
//  感知 macOS 系统电量与热状态，动态调整后台轮询与资源调度
//

import AppKit
import Combine
import Foundation

/// 能耗调度策略配置
struct EnergyProfile: Sendable, Equatable {
    /// 活跃巡检间隔（秒）
    let activeInterval: TimeInterval
    /// 空闲节电巡检间隔（秒）
    let idleInterval: TimeInterval
    /// 连续无变动多少次后进入空闲节电模式
    let idleThresholdTicks: Int

    /// 标准性能模式（默认供电良好时）
    static let standard = EnergyProfile(
        activeInterval: 0.12,
        idleInterval: 1.2,
        idleThresholdTicks: 10
    )

    /// 低电量/节能减排模式（macOS Monterey+ 低电量模式或热保护）
    static let powerSaving = EnergyProfile(
        activeInterval: 0.25,
        idleInterval: 3.0,
        idleThresholdTicks: 4
    )
}

@MainActor
final class SystemEnergyMonitor: ObservableObject {
    static let shared = SystemEnergyMonitor()

    @Published private(set) var isLowPowerMode: Bool = false
    @Published private(set) var isThermalThrottled: Bool = false

    var currentProfile: EnergyProfile {
        (isLowPowerMode || isThermalThrottled) ? .powerSaving : .standard
    }

    /// 策略发生变更时的回调通知
    var onProfileDidChange: ((EnergyProfile) -> Void)?

    private var observers: [NSObjectProtocol] = []

    init() {
        refreshState()
        setupObservers()
    }

    func refreshState() {
        let lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
        let thermal = ProcessInfo.processInfo.thermalState == .serious || ProcessInfo.processInfo.thermalState == .critical

        if lowPower != isLowPowerMode || thermal != isThermalThrottled {
            isLowPowerMode = lowPower
            isThermalThrottled = thermal
            onProfileDidChange?(currentProfile)
        }
    }

    private func setupObservers() {
        let center = NotificationCenter.default

        // 监听 macOS 低电量模式开启/关闭通知
        let obs1 = center.addObserver(
            forName: .NSProcessInfoPowerStateDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.refreshState()
            }
        }

        // 监听系统发热状态变更
        let obs2 = center.addObserver(
            forName: ProcessInfo.thermalStateDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.refreshState()
            }
        }

        observers = [obs1, obs2]
    }
}
