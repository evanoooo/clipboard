//
//  OCRViewService.swift
//  Clipboard
//
//  Created by crown on 2026/01/01.
//

import AppKit
import Vision

actor OCRViewService {
    static let shared = OCRViewService()

    private let maxConcurrentTasks = 2
    private var activeTasks = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []

    private init() {}

    private func acquireSlot() async {
        if activeTasks < maxConcurrentTasks {
            activeTasks += 1
            return
        }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    private func releaseSlot() {
        if !waiters.isEmpty {
            let next = waiters.removeFirst()
            next.resume()
        } else {
            activeTasks = max(0, activeTasks - 1)
        }
    }

    func recognizeText(from data: Data, priority: TaskPriority = .utility) async -> String {
        await acquireSlot()
        defer { releaseSlot() }

        let tempURL = FileManager.default.temporaryDirectory
            .appending(path: "clip-ocr-\(UUID().uuidString).img")
        do {
            try data.write(to: tempURL, options: .atomic)
            defer { try? FileManager.default.removeItem(at: tempURL) }
            if let isolatedResult = await OCRWorkerClient.shared.recognize(fileURL: tempURL) {
                return isolatedResult
            }
        } catch {
            // 临时文件写入失败时降级为本地识别
        }

        return await Task.detached(priority: priority) {
            OCRWorkerProcess.recognizeData(data)
        }.value
    }

    func recognizeText(at fileURL: URL, priority: TaskPriority = .utility) async -> String {
        await acquireSlot()
        defer { releaseSlot() }

        if let isolatedResult = await OCRWorkerClient.shared.recognize(fileURL: fileURL) {
            return isolatedResult
        }

        return await Task.detached(priority: priority) {
            OCRWorkerProcess.recognizeFile(at: fileURL)
        }.value
    }
}
