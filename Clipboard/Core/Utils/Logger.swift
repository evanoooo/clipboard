//
//  Logger.swift
//  clipboard
//
//  Created by crown on 2025/6/14.
//

import Foundation
import os.log

enum LogLevel: String, CaseIterable, Comparable {
    case debug = "DEBUG"
    case info = "INFO"
    case warning = "WARNING"
    case error = "ERROR"

    var osLogType: OSLogType {
        switch self {
        case .debug: .debug
        case .info: .info
        case .warning: .default
        case .error: .error
        }
    }

    nonisolated var priority: Int {
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

/// Thread-safe logger. Public methods are nonisolated so callers need no `await`.
/// File I/O is serialised inside the actor.
final class AppLogger: Sendable {
    nonisolated static let shared = AppLogger()

    private let osLogger = os.Logger(subsystem: "com.crown.clipboard", category: "AppLogger")
    private let _state: LoggerState
    /// 非隔离的级别快照：低于级别的日志不再派发 Task，避免热路径上白白入队。
    private let minimumLevel = OSAllocatedUnfairLock(initialState: AppLogger.defaultLevel)

    private nonisolated static var defaultLevel: LogLevel {
        #if DEBUG
            .debug
        #else
            .info
        #endif
    }

    private nonisolated init() {
        _state = LoggerState()
    }

    // MARK: - Public API (nonisolated — safe to call from any actor or thread)

    nonisolated func debug(_ message: String, file: String = #file, function: String = #function, line: Int = #line) {
        emit(message, level: .debug, file: file, function: function, line: line)
    }

    nonisolated func info(_ message: String, file: String = #file, function: String = #function, line: Int = #line) {
        emit(message, level: .info, file: file, function: function, line: line)
    }

    nonisolated func warn(_ message: String, file: String = #file, function: String = #function, line: Int = #line) {
        emit(message, level: .warning, file: file, function: function, line: line)
    }

    nonisolated func error(_ message: String, file: String = #file, function: String = #function, line: Int = #line) {
        emit(message, level: .error, file: file, function: function, line: line)
    }

    nonisolated func setMinimumLogLevel(_ level: LogLevel) {
        minimumLevel.withLock { $0 = level }
    }

    // MARK: - Private

    private nonisolated func emit(_ message: String, level: LogLevel, file: String, function: String, line: Int) {
        guard level >= minimumLevel.withLock({ $0 }) else { return }

        let fileName = URL(fileURLWithPath: file).lastPathComponent
        let timestamp = Date().formatted(LoggerState.timestampFormat)
        #if DEBUG
            print("\(timestamp) [\(level.rawValue)] [\(fileName):\(line)] \(message)")
        #else
            let logMessage = "[\(fileName):\(line)] \(function) - \(message)"
            if level == .error {
                osLogger.error("\(logMessage)")
            }
            Task { await _state.write(logMessage, level: level, timestamp: timestamp) }
        #endif
    }
}

// MARK: - Actor-isolated state

private actor LoggerState {
    static let timestampFormat: Date.FormatStyle = .dateTime
        .year().month().day()
        .hour(.twoDigits(amPM: .omitted)).minute(.twoDigits).second(.twoDigits)

    private static let fileDateFormat = Date.VerbatimFormatStyle(
        format: "\(year: .defaultDigits)\(month: .twoDigits)\(day: .twoDigits)",
        timeZone: .current,
        calendar: Calendar(identifier: .gregorian)
    )

    #if DEBUG
        private var minimumLogLevel: LogLevel = .debug
    #else
        private var minimumLogLevel: LogLevel = .info
    #endif
    private let logsDirectory: URL? = {
        #if DEBUG
            return nil
        #else
            let logsDir = URL.applicationSupportDirectory.appending(path: "com.crown.clipboard/logs")
            try? FileManager.default.createDirectory(at: logsDir, withIntermediateDirectories: true)
            return logsDir
        #endif
    }()

    private var cachedLogFileURL: URL?
    private var cachedDayBoundary: TimeInterval = 0

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

    private func currentLogFileURL() -> URL? {
        guard let logsDirectory else { return nil }
        let now = Date()
        if now.timeIntervalSinceReferenceDate < cachedDayBoundary, let cachedLogFileURL {
            return cachedLogFileURL
        }
        let calendar = Calendar(identifier: .gregorian)
        let nextDay = calendar.startOfDay(for: now).addingTimeInterval(86400)
        let url = logsDirectory.appending(path: "clip-\(now.formatted(Self.fileDateFormat)).log")
        cachedLogFileURL = url
        cachedDayBoundary = nextDay.timeIntervalSinceReferenceDate
        purgeOldLogs()
        return url
    }

    func setMinimumLogLevel(_ level: LogLevel) {
        minimumLogLevel = level
    }

    func write(_ message: String, level: LogLevel, timestamp: String) {
        guard let logFileURL = currentLogFileURL() else { return }
        let logEntry = "[\(timestamp)] [\(level.rawValue)] \(message)\n"
        guard let data = logEntry.data(using: .utf8) else { return }
        if FileManager.default.fileExists(atPath: logFileURL.path) {
            if let fileHandle = try? FileHandle(forWritingTo: logFileURL) {
                defer { _ = try? fileHandle.close() }
                _ = try? fileHandle.seekToEnd()
                _ = try? fileHandle.write(contentsOf: data)
            }
        } else {
            try? data.write(to: logFileURL)
        }
    }
}

nonisolated let log = AppLogger.shared
