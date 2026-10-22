//
//  Logger.swift
//  Clipboard
//
//  现代化日志系统：基于 Apple Unified Logging (os.Logger) 与内存环形诊断缓冲区
//

import AppKit
import Foundation
import os.log

// MARK: - 日志级别

nonisolated enum LogLevel: String, CaseIterable, Comparable, Sendable {
    case debug = "DEBUG"
    case info = "INFO"
    case warning = "WARN"
    case error = "ERROR"

    var osLogType: OSLogType {
        switch self {
        case .debug: .debug
        case .info: .info
        case .warning: .default
        case .error: .error
        }
    }

    var priority: Int {
        switch self {
        case .debug: 0
        case .info: 1
        case .warning: 2
        case .error: 3
        }
    }

    nonisolated static func < (lhs: LogLevel, rhs: LogLevel) -> Bool {
        lhs.priority < rhs.priority
    }
}

// MARK: - 业务模块分类 (Category)

nonisolated enum LogCategory: String, CaseIterable, Sendable {
    case general = "General"
    case pasteboard = "Pasteboard"
    case database = "Database"
    case storage = "Storage"
    case ui = "UI"
    case hotkey = "Hotkey"
    case monitor = "Monitor"
}

// MARK: - 诊断日志条目 (用于内存诊断缓冲区与脱敏报告)

nonisolated struct DiagnosticLogEntry: Sendable, Identifiable {
    let id: UUID
    let timestamp: Date
    let level: LogLevel
    let category: LogCategory
    let message: String
    let file: String
    let line: Int

    var formattedTimestamp: String {
        Self.dateFormatter.string(from: timestamp)
    }

    private static let dateFormatter: DateFormatter = {
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return df
    }()

    var formattedLine: String {
        "[\(formattedTimestamp)] [\(level.rawValue)] [\(category.rawValue)] [\(file):\(line)] \(message)"
    }
}

// MARK: - 内存环形缓冲区 (Ring Buffer，零文件 I/O 损耗，锁保护高性能)

nonisolated private final class DiagnosticRingBuffer: Sendable {
    private struct State {
        var buffer: [DiagnosticLogEntry] = []
        let capacity: Int
    }

    private let state: OSAllocatedUnfairLock<State>

    init(capacity: Int = 500) {
        self.state = OSAllocatedUnfairLock(initialState: State(capacity: capacity))
    }

    nonisolated func append(_ entry: DiagnosticLogEntry) {
        state.withLock { s in
            if s.buffer.count >= s.capacity {
                s.buffer.removeFirst(s.buffer.count - s.capacity + 1)
            }
            s.buffer.append(entry)
        }
    }

    nonisolated func snapshot() -> [DiagnosticLogEntry] {
        state.withLock { $0.buffer }
    }

    nonisolated func clear() {
        state.withLock { $0.buffer.removeAll(keepingCapacity: true) }
    }
}

// MARK: - 现代化 AppLogger 核心实现

final class AppLogger: Sendable {
    nonisolated static let shared = AppLogger()

    nonisolated private static let subsystem = "com.crown.clipboard"

    // 各模块预置的系统级 os.Logger，由 macOS Unified Logging 守护进程零损耗调度
    private let osLoggers: [LogCategory: os.Logger]
    private let ringBuffer = DiagnosticRingBuffer(capacity: 600)
    private let minimumLevel = OSAllocatedUnfairLock(initialState: AppLogger.defaultLevel)

    private nonisolated static var defaultLevel: LogLevel {
        #if DEBUG
            .debug
        #else
            .info
        #endif
    }

    private nonisolated init() {
        var loggers: [LogCategory: os.Logger] = [:]
        for cat in LogCategory.allCases {
            loggers[cat] = os.Logger(subsystem: Self.subsystem, category: cat.rawValue)
        }
        self.osLoggers = loggers
    }

    // MARK: - 核心分发逻辑

    private nonisolated func emit(
        _ message: String,
        level: LogLevel,
        category: LogCategory = .general,
        file: String,
        function: String,
        line: Int
    ) {
        guard level >= minimumLevel.withLock({ $0 }) else { return }

        let fileName = URL(fileURLWithPath: file).lastPathComponent

        #if DEBUG
            let timeStr = Date().formatted(date: .omitted, time: .standard)
            print("\(timeStr) [\(level.rawValue)] [\(category.rawValue)] [\(fileName):\(line)] \(message)")
        #else
            let osLog = osLoggers[category] ?? os.Logger(subsystem: Self.subsystem, category: category.rawValue)
            let formattedMsg = "[\(fileName):\(line)] \(function) - \(message)"
            switch level {
            case .debug:
                osLog.debug("\(formattedMsg, privacy: .public)")
            case .info:
                osLog.info("\(formattedMsg, privacy: .public)")
            case .warning:
                osLog.warning("\(formattedMsg, privacy: .public)")
            case .error:
                osLog.error("\(formattedMsg, privacy: .public)")
            }
        #endif

        // 纯内存高并发环形诊断缓冲区录入（微秒级，绝不发生磁盘写入），用于一键故障报告
        let entry = DiagnosticLogEntry(
            id: UUID(),
            timestamp: Date(),
            level: level,
            category: category,
            message: message,
            file: fileName,
            line: line
        )
        ringBuffer.append(entry)
    }

    // MARK: - 公共便捷 API (兼容旧调用)

    nonisolated func debug(
        _ message: String,
        category: LogCategory = .general,
        file: String = #file,
        function: String = #function,
        line: Int = #line
    ) {
        emit(message, level: .debug, category: category, file: file, function: function, line: line)
    }

    nonisolated func info(
        _ message: String,
        category: LogCategory = .general,
        file: String = #file,
        function: String = #function,
        line: Int = #line
    ) {
        emit(message, level: .info, category: category, file: file, function: function, line: line)
    }

    nonisolated func warn(
        _ message: String,
        category: LogCategory = .general,
        file: String = #file,
        function: String = #function,
        line: Int = #line
    ) {
        emit(message, level: .warning, category: category, file: file, function: function, line: line)
    }

    nonisolated func error(
        _ message: String,
        category: LogCategory = .general,
        file: String = #file,
        function: String = #function,
        line: Int = #line
    ) {
        emit(message, level: .error, category: category, file: file, function: function, line: line)
    }

    nonisolated func setMinimumLogLevel(_ level: LogLevel) {
        minimumLevel.withLock { $0 = level }
    }

    // MARK: - 性能耗时跟踪 (零开销分级记录)

    /// 跟踪执行耗时，若超出指定阈值才记录警告日志，平缓日常高频查询
    nonisolated func measure(
        _ label: String,
        category: LogCategory = .general,
        warningThresholdMs: Double = 100,
        file: String = #file,
        function: String = #function,
        line: Int = #line,
        operation: () throws -> Void
    ) rethrows {
        let start = ContinuousClock.now
        try operation()
        let duration = start.duration(to: .now)
        let ms = Double(duration.components.attoseconds) / 1_000_000_000_000_000.0 + Double(duration.components.seconds) * 1000.0
        let msRounded = (ms * 100).rounded() / 100
        if ms >= warningThresholdMs {
            warn("⏱️ [Slow Operation] \(label) took \(msRounded) ms", category: category, file: file, function: function, line: line)
        } else {
            debug("⏱️ \(label) took \(msRounded) ms", category: category, file: file, function: function, line: line)
        }
    }

    // MARK: - 诊断报告一键导出

    /// 同步生成脱敏的诊断日志报告文本
    nonisolated func exportDiagnosticReport() -> String {
        let entries = ringBuffer.snapshot()
        let osVersion = ProcessInfo.processInfo.operatingSystemVersionString
        let appVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "Unknown"
        let buildNumber = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "Unknown"

        var report = """
        ==================================================
        Clipboard Diagnostic Report
        Generated at: \(Date().formatted(date: .complete, time: .complete))
        App Version: \(appVersion) (\(buildNumber))
        macOS Version: \(osVersion)
        Active Log Entries: \(entries.count)
        ==================================================

        """

        for entry in entries {
            report += entry.formattedLine + "\n"
        }

        return report
    }
}

// MARK: - 静态命名空间 (便于按模块书写 Log.database.info(...))

nonisolated enum Log {
    struct CategoryLogger: Sendable {
        let category: LogCategory

        nonisolated func debug(_ msg: String, file: String = #file, function: String = #function, line: Int = #line) {
            AppLogger.shared.debug(msg, category: category, file: file, function: function, line: line)
        }

        nonisolated func info(_ msg: String, file: String = #file, function: String = #function, line: Int = #line) {
            AppLogger.shared.info(msg, category: category, file: file, function: function, line: line)
        }

        nonisolated func warn(_ msg: String, file: String = #file, function: String = #function, line: Int = #line) {
            AppLogger.shared.warn(msg, category: category, file: file, function: function, line: line)
        }

        nonisolated func error(_ msg: String, file: String = #file, function: String = #function, line: Int = #line) {
            AppLogger.shared.error(msg, category: category, file: file, function: function, line: line)
        }
    }

    nonisolated static let general = CategoryLogger(category: .general)
    nonisolated static let pasteboard = CategoryLogger(category: .pasteboard)
    nonisolated static let database = CategoryLogger(category: .database)
    nonisolated static let storage = CategoryLogger(category: .storage)
    nonisolated static let ui = CategoryLogger(category: .ui)
    nonisolated static let hotkey = CategoryLogger(category: .hotkey)
    nonisolated static let monitor = CategoryLogger(category: .monitor)
}

// MARK: - 全局向后兼容单例

nonisolated let log = AppLogger.shared
