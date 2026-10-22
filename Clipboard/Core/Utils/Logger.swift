//
//  Logger.swift
//  Clipboard
//
//  现代化日志系统：基于 Apple Unified Logging (os.Logger)、内存诊断环形缓冲区与异步批量写盘队列
//

import AppKit
import Foundation
import os.log

// MARK: - 日志级别

nonisolated enum LogLevel: String, CaseIterable, Comparable, Identifiable, Sendable {
    case debug = "DEBUG"
    case info = "INFO"
    case warning = "WARN"
    case error = "ERROR"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .debug: return "调试 (Debug)"
        case .info: return "标准 (Info - 推荐)"
        case .warning: return "仅告警 (Warn)"
        case .error: return "仅错误 (Error)"
        }
    }

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

// MARK: - 异步队列批量落盘写入器 (Async Batching File Writer)

nonisolated private final class AsyncFileLogWriter: @unchecked Sendable {
    private let writeQueue = DispatchQueue(label: "com.crown.clipboard.log-writer", qos: .utility)
    private let logsDirectory: URL?
    private var pendingEntries: [String] = []
    private var flushWorkItem: DispatchWorkItem?
    private var currentFileHandle: FileHandle?
    private var currentDateString: String = ""

    init() {
        let dir = URL.applicationSupportDirectory.appending(path: "com.crown.clipboard/logs")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        self.logsDirectory = dir

        writeQueue.async { [weak self] in
            self?.purgeOldLogs()
        }
    }

    nonisolated func enqueue(_ logLine: String) {
        writeQueue.async { [weak self] in
            guard let self else { return }
            self.pendingEntries.append(logLine + "\n")

            // 批量触发：满 20 条立即落盘，否则 1 秒去抖冲刷
            if self.pendingEntries.count >= 20 {
                self.flushWorkItem?.cancel()
                self.flushWorkItem = nil
                self.flushPending()
            } else if self.flushWorkItem == nil {
                let item = DispatchWorkItem { [weak self] in
                    self?.flushWorkItem = nil
                    self?.flushPending()
                }
                self.flushWorkItem = item
                self.writeQueue.asyncAfter(deadline: .now() + 1.0, execute: item)
            }
        }
    }

    nonisolated func flushSync() {
        writeQueue.sync {
            self.flushWorkItem?.cancel()
            self.flushWorkItem = nil
            self.flushPending()
        }
    }

    private func flushPending() {
        guard !pendingEntries.isEmpty, let logsDirectory else { return }
        let now = Date()
        let dateStr = now.formatted(Self.fileDateFormat)

        // 跨天检测：轮转关闭旧句柄
        if dateStr != currentDateString {
            try? currentFileHandle?.close()
            currentFileHandle = nil
            currentDateString = dateStr
            purgeOldLogs()
        }

        let fileURL = logsDirectory.appending(path: "clip-\(dateStr).log")

        if currentFileHandle == nil {
            if !FileManager.default.fileExists(atPath: fileURL.path) {
                FileManager.default.createFile(atPath: fileURL.path, contents: nil)
            }
            if let handle = try? FileHandle(forWritingTo: fileURL) {
                _ = try? handle.seekToEnd()
                currentFileHandle = handle
            }
        }

        guard let handle = currentFileHandle else { return }

        let combinedString = pendingEntries.joined()
        if let data = combinedString.data(using: .utf8) {
            _ = try? handle.write(contentsOf: data)
        }
        pendingEntries.removeAll(keepingCapacity: true)
    }

    private func purgeOldLogs(before days: Int = 7) {
        guard let logsDirectory else { return }
        let cutoff = Date().addingTimeInterval(-Double(days * 86400))
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: logsDirectory,
            includingPropertiesForKeys: [.contentModificationDateKey]
        ) else { return }
        for file in files where file.pathExtension == "log" {
            if let values = try? file.resourceValues(forKeys: [.contentModificationDateKey]),
               let date = values.contentModificationDate,
               date < cutoff {
                try? FileManager.default.removeItem(at: file)
            }
        }
    }

    nonisolated private static let fileDateFormat = Date.VerbatimFormatStyle(
        format: "\(year: .defaultDigits)\(month: .twoDigits)\(day: .twoDigits)",
        timeZone: .current,
        calendar: Calendar(identifier: .gregorian)
    )
}

// MARK: - 现代化 AppLogger 核心实现

final class AppLogger: Sendable {
    nonisolated static let shared = AppLogger()

    nonisolated private static let subsystem = "com.crown.clipboard"

    // 各模块预置的系统级 os.Logger，由 macOS Unified Logging 守护进程调度
    private let osLoggers: [LogCategory: os.Logger]
    private let ringBuffer = DiagnosticRingBuffer(capacity: 600)
    private let fileWriter = AsyncFileLogWriter()
    private let minimumLevel = OSAllocatedUnfairLock(initialState: AppLogger.initialLevel)

    private nonisolated static var initialLevel: LogLevel {
        if let raw = UserDefaults.standard.string(forKey: "appLogLevel"), let level = LogLevel(rawValue: raw) {
            return level
        }
        return .info
    }

    nonisolated var currentMinimumLogLevel: LogLevel {
        minimumLevel.withLock { $0 }
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

        let timestamp = Date()

        // 1. 录入内存环形诊断缓冲区（微秒级，用于一键故障报告）
        let entry = DiagnosticLogEntry(
            id: UUID(),
            timestamp: timestamp,
            level: level,
            category: category,
            message: message,
            file: fileName,
            line: line
        )
        ringBuffer.append(entry)

        // 2. 投递到异步批量写盘队列，平滑写入 clip-YYYYMMDD.log（零阻塞主线程）
        let fileLogLine = "[\(timestamp.formatted(Self.fileTimestampFormat))] [\(level.rawValue)] [\(category.rawValue)] [\(fileName):\(line)] \(function) - \(message)"
        fileWriter.enqueue(fileLogLine)
    }

    nonisolated private static let fileTimestampFormat: Date.FormatStyle = .dateTime
        .year().month().day()
        .hour(.twoDigits(amPM: .omitted)).minute(.twoDigits).second(.twoDigits)

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
        UserDefaults.standard.set(level.rawValue, forKey: "appLogLevel")
    }

    /// 打开访达定位日志目录
    nonisolated func openLogsDirectory() {
        let dir = URL.applicationSupportDirectory.appending(path: "com.crown.clipboard/logs")
        DispatchQueue.main.async {
            NSWorkspace.shared.open(dir)
        }
    }

    /// 清空历史日志
    nonisolated func clearHistoricalLogs() {
        let dir = URL.applicationSupportDirectory.appending(path: "com.crown.clipboard/logs")
        guard let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { return }
        for file in files where file.pathExtension == "log" {
            try? FileManager.default.removeItem(at: file)
        }
    }

    /// 立即同步冲刷异步写盘队列（如应用即将退出时）
    nonisolated func flushSync() {
        fileWriter.flushSync()
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
