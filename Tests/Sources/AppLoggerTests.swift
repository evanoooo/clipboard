//
//  AppLoggerTests.swift
//  Tests
//
//  Unit tests for modern logging system, category routing, ring buffer and diagnostic export.
//

import AppKit
import Foundation

@MainActor
enum AppLoggerTests {
    static func run(runner: TestRunner.Type) {
        print("\n--- Testing AppLogger & Modern Diagnostic System ---")
        testLogLevelPriority(runner: runner)
        testLogCategoryCoverage(runner: runner)
        testDiagnosticLogEntryFormatting(runner: runner)
        testRingBufferAndExport(runner: runner)
        testMeasureSlowOperation(runner: runner)
        print("✓ AppLogger & Modern Diagnostic tests passed!")
    }

    private static func testLogLevelPriority(runner: TestRunner.Type) {
        runner.assertTrue(LogLevel.debug < LogLevel.info, "Debug should have lower priority than Info")
        runner.assertTrue(LogLevel.info < LogLevel.warning, "Info should have lower priority than Warning")
        runner.assertTrue(LogLevel.warning < LogLevel.error, "Warning should have lower priority than Error")
        runner.assertEqual(LogLevel.debug.osLogType, .debug, "Debug should map to os.log .debug")
        runner.assertEqual(LogLevel.error.osLogType, .error, "Error should map to os.log .error")
    }

    private static func testLogCategoryCoverage(runner: TestRunner.Type) {
        let expectedCategories: Set<String> = [
            "General", "Pasteboard", "Database", "Storage", "UI", "Hotkey", "Monitor", "Sync"
        ]
        let actualCategories = Set(LogCategory.allCases.map(\.rawValue))
        runner.assertEqual(actualCategories, expectedCategories, "All predefined categories must be covered")
    }

    private static func testDiagnosticLogEntryFormatting(runner: TestRunner.Type) {
        let entry = DiagnosticLogEntry(
            id: UUID(),
            timestamp: Date(timeIntervalSince1970: 1700000000),
            level: .error,
            category: .database,
            message: "Table corruption simulated",
            file: "PasteSQLManager.swift",
            line: 42
        )
        let formatted = entry.formattedLine
        runner.assertTrue(formatted.contains("[ERROR]"), "Formatted entry must contain level")
        runner.assertTrue(formatted.contains("[Database]"), "Formatted entry must contain category")
        runner.assertTrue(formatted.contains("[PasteSQLManager.swift:42]"), "Formatted entry must contain location")
        runner.assertTrue(formatted.contains("Table corruption simulated"), "Formatted entry must contain message")
    }

    private static func testRingBufferAndExport(runner: TestRunner.Type) {
        let logger = AppLogger.shared
        // 记录不同级别的日志
        logger.info("Diagnostic test info message", category: .storage)
        logger.warn("Diagnostic test warning message", category: .database)
        logger.error("Diagnostic test error message", category: .pasteboard)

        // 同步直接获取诊断报告，零阻塞
        let reportContent = logger.exportDiagnosticReport()

        runner.assertTrue(reportContent.contains("Clipboard Diagnostic Report"), "Report should have title header")
        runner.assertTrue(reportContent.contains("macOS Version:"), "Report should include OS information")
        runner.assertTrue(reportContent.contains("Active Log Entries:"), "Report should include entry count")
        runner.assertTrue(reportContent.contains("Diagnostic test error message"), "Report must include logged error message")
    }

    private static func testMeasureSlowOperation(runner: TestRunner.Type) {
        let logger = AppLogger.shared
        var executed = false
        logger.measure("Fast Task", category: .ui, warningThresholdMs: 500) {
            executed = true
        }
        runner.assertTrue(executed, "Measure must execute the given operation")
    }
}
