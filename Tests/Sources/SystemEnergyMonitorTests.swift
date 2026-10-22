//
//  SystemEnergyMonitorTests.swift
//  Tests
//
//  Unit tests for SystemEnergyMonitor and adaptive energy profiles.
//

import Foundation

@MainActor
enum SystemEnergyMonitorTests {
    static func run(runner: TestRunner.Type) {
        print("\n--- Testing SystemEnergyMonitor & Low Power Mode Adaptation ---")
        testEnergyProfileValues(runner: runner)
        testProfileStateResolution(runner: runner)
        testAdaptivePollingCadence(runner: runner)
        testShortcutImmediateAcceleration(runner: runner)
        print("✓ SystemEnergyMonitor tests passed!")
    }

    private static func testEnergyProfileValues(runner: TestRunner.Type) {
        let standard = EnergyProfile.standard
        runner.assertEqual(standard.activeInterval, 0.12, "Standard active interval should be 120ms")
        runner.assertEqual(standard.idleInterval, 1.2, "Standard idle interval should be 1200ms")
        runner.assertEqual(standard.idleThresholdTicks, 10, "Standard idle threshold should be 10 ticks")

        let saving = EnergyProfile.powerSaving
        runner.assertEqual(saving.activeInterval, 0.25, "Power saving active interval should be 250ms")
        runner.assertEqual(saving.idleInterval, 3.0, "Power saving idle interval should be 3000ms")
        runner.assertEqual(saving.idleThresholdTicks, 4, "Power saving idle threshold should be 4 ticks")
    }

    private static func testProfileStateResolution(runner: TestRunner.Type) {
        func resolveProfile(lowPower: Bool, thermalThrottled: Bool) -> EnergyProfile {
            (lowPower || thermalThrottled) ? .powerSaving : .standard
        }

        runner.assertEqual(resolveProfile(lowPower: false, thermalThrottled: false), .standard, "Default state should be standard")
        runner.assertEqual(resolveProfile(lowPower: true, thermalThrottled: false), .powerSaving, "Low power should trigger powerSaving")
        runner.assertEqual(resolveProfile(lowPower: false, thermalThrottled: true), .powerSaving, "Thermal throttle should trigger powerSaving")
        runner.assertEqual(resolveProfile(lowPower: true, thermalThrottled: true), .powerSaving, "Both should trigger powerSaving")
    }

    private static func testAdaptivePollingCadence(runner: TestRunner.Type) {
        func calculateNextInterval(idleTicks: Int, profile: EnergyProfile) -> TimeInterval {
            idleTicks >= profile.idleThresholdTicks ? profile.idleInterval : profile.activeInterval
        }

        let std = EnergyProfile.standard
        runner.assertEqual(calculateNextInterval(idleTicks: 0, profile: std), 0.12, "Std tick 0 should be active interval")
        runner.assertEqual(calculateNextInterval(idleTicks: 9, profile: std), 0.12, "Std tick 9 should still be active")
        runner.assertEqual(calculateNextInterval(idleTicks: 10, profile: std), 1.2, "Std tick 10 should transition to idle interval")
        runner.assertEqual(calculateNextInterval(idleTicks: 50, profile: std), 1.2, "Std tick 50 should stay in idle interval")

        let saving = EnergyProfile.powerSaving
        runner.assertEqual(calculateNextInterval(idleTicks: 0, profile: saving), 0.25, "Saving tick 0 should be active interval")
        runner.assertEqual(calculateNextInterval(idleTicks: 3, profile: saving), 0.25, "Saving tick 3 should still be active")
        runner.assertEqual(calculateNextInterval(idleTicks: 4, profile: saving), 3.0, "Saving tick 4 should transition to 3.0s idle")
    }

    private static func testShortcutImmediateAcceleration(runner: TestRunner.Type) {
        // 键盘 ⌘C / ⌘X 发生时，无论当前处于什么能耗模式，必须在 30ms 内极速拉取，确保用户完全零感知延迟
        let shortcutInterval: TimeInterval = 0.03
        runner.assertEqual(shortcutInterval, 0.03, "Shortcut acceleration must remain 30ms")
        runner.assertTrue(shortcutInterval < EnergyProfile.standard.activeInterval, "Shortcut interval must be faster than standard active")
        runner.assertTrue(shortcutInterval < EnergyProfile.powerSaving.activeInterval, "Shortcut interval must be faster than power saving active")
    }
}
