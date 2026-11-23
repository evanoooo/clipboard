//
//  SyncEngine+Scheduling.swift
//  Clipboard
//
//  云同步电源/休眠生命周期监听、脏数据防抖与周期调度
//

import AppKit
import Foundation

extension SyncEngine {
    func setupPowerAndSleepObservers() {
        let center = NSWorkspace.shared.notificationCenter

        // 系统即将休眠：优雅中断正在进行的同步传输，防止在休眠中挂起导致唤醒后超时
        let obsSleep = center.addObserver(
            forName: NSWorkspace.willSleepNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if self.currentState == .syncing {
                    self.addLog("系统即将进入休眠，优雅中止后台同步任务")
                    self.cancelSync()
                }
                self.periodicSyncTimer?.invalidate()
                self.periodicSyncTimer = nil
            }
        }

        // 系统唤醒恢复：延迟 5 秒待 Wi-Fi 重连稳定后，如有脏数据自动触发增量同步
        let obsWake = center.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor [weak self] in
                guard let self else { return }
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                self.updateSyncSchedule()
                if UserDefaults.standard.bool(forKey: "sync_enabled"), self.isDirty {
                    self.addLog("系统唤醒网络已恢复，自动执行增量同步")
                    self.startSyncTask()
                }
            }
        }

        powerObservers = [obsSleep, obsWake]
    }

    func markDirtyAndSchedule() {
        guard UserDefaults.standard.bool(forKey: "sync_enabled") else { return }
        isDirty = true
        dirtyGeneration &+= 1
        debounceTask?.cancel()

        let freq = SyncFrequency.current
        guard freq != .off else { return }

        if freq == .realtime {
            let isPowerSaving = ProcessInfo.processInfo.isLowPowerModeEnabled
            let delayNanoseconds: UInt64 = isPowerSaving ? 60_000_000_000 : 15_000_000_000

            debounceTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: delayNanoseconds)
                guard !Task.isCancelled else { return }
                self?.startSyncTask()
            }
        } else if periodicSyncTimer == nil {
            updateSyncSchedule()
        }
    }

    func updateSyncSchedule() {
        periodicSyncTimer?.invalidate()
        periodicSyncTimer = nil
        debounceTask?.cancel()
        debounceTask = nil

        guard UserDefaults.standard.bool(forKey: "sync_enabled") else { return }
        let freq = SyncFrequency.current
        guard freq != .off else { return }

        if freq != .realtime {
            let interval = TimeInterval(freq.rawValue)
            let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    guard UserDefaults.standard.bool(forKey: "sync_enabled") else { return }
                    self.addLog("触发周期自动同步 (\(freq.title))")
                    self.startSyncTask()
                }
            }
            // 遵循 Apple 能耗规范：设置 10% 容差，允许 macOS 内核进行定时器聚合，显著降低电池唤醒能耗
            timer.tolerance = interval * 0.1
            RunLoop.main.add(timer, forMode: .common)
            periodicSyncTimer = timer
        }
    }
}
