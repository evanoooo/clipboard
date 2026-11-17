//
//  OCRWorkerProcess.swift
//  Clipboard
//
//  独立 OCR 子进程隔离引擎：
//  主进程零 Vision/Espresso 脏内存常驻；子进程通过 stdin/stdout 管道接收图像路径，
//  闲置 10 秒后自动退出，将 ~60–110MB 神经网络权重与 C++ 堆内存完整归还操作系统。
//

import CoreGraphics
import Foundation
import Vision

nonisolated enum OCRWorkerProcess {
    struct Request: Codable, Sendable {
        let id: String
        let path: String
    }

    struct Response: Codable, Sendable {
        let id: String
        let text: String
    }

    /// 子进程入口（在 `--ocr-worker` 模式下运行，不启动 AppKit/UI）
    static func runLoop() {
        let idleTimeoutSeconds: TimeInterval = 10
        let queue = DispatchQueue(label: "com.crown.clipboard.ocr-worker.watchdog")
        var lastActivity = DispatchTime.now()
        var isBusy = false

        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 2, repeating: 2)
        timer.setEventHandler {
            guard !isBusy else { return }
            let elapsed = Double(DispatchTime.now().uptimeNanoseconds - lastActivity.uptimeNanoseconds) / 1_000_000_000
            if elapsed >= idleTimeoutSeconds {
                Foundation.exit(0)
            }
        }
        timer.resume()

        let decoder = JSONDecoder()
        let encoder = JSONEncoder()
        let stdout = FileHandle.standardOutput

        while let line = readLine(strippingNewline: true) {
            queue.sync {
                isBusy = true
                lastActivity = .now()
            }
            defer {
                queue.sync {
                    isBusy = false
                    lastActivity = .now()
                }
            }

            guard let lineData = line.data(using: .utf8),
                  let req = try? decoder.decode(Request.self, from: lineData) else {
                continue
            }

            let recognized = recognizeFile(at: URL(fileURLWithPath: req.path))
            let resp = Response(id: req.id, text: recognized)
            if let encoded = try? encoder.encode(resp) {
                var payload = encoded
                payload.append(0x0A) // '\n'
                stdout.write(payload)
            }
        }

        timer.cancel()
        Foundation.exit(0)
    }

    static func recognizeFile(at url: URL) -> String {
        autoreleasepool {
            guard let cgImage = ImageDownsampler.downsampleCGImage(from: url, maxPixelSize: 3000) else {
                return ""
            }
            return performVisionOCR(on: cgImage)
        }
    }

    static func recognizeData(_ data: Data) -> String {
        autoreleasepool {
            guard let cgImage = ImageDownsampler.downsampleCGImage(from: data, maxPixelSize: 3000) else {
                return ""
            }
            return performVisionOCR(on: cgImage)
        }
    }

    private static func performVisionOCR(on cgImage: CGImage) -> String {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["zh-Hans", "zh-Hant", "en-US"]
        request.usesLanguageCorrection = true

        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        do {
            try handler.perform([request])
            return (request.results ?? [])
                .compactMap { $0.topCandidates(1).first?.string }
                .joined(separator: "\n")
        } catch {
            return ""
        }
    }
}

/// 主进程侧 XPC-like 管道客户端：按需拉起 `--ocr-worker` 子进程并在异常时安全兜底
actor OCRWorkerClient {
    static let shared = OCRWorkerClient()

    private var process: Process?
    private var stdinHandle: FileHandle?
    private var stdoutHandle: FileHandle?
    private var readerTask: Task<Void, Never>?
    private var pending: [String: CheckedContinuation<String, Never>] = [:]

    private init() {}

    func recognize(fileURL: URL) async -> String? {
        guard ensureWorkerRunning(), let stdinHandle else {
            return nil
        }

        let requestID = UUID().uuidString
        let req = OCRWorkerProcess.Request(id: requestID, path: fileURL.path)
        guard var payload = try? JSONEncoder().encode(req) else {
            return nil
        }
        payload.append(0x0A)

        return await withCheckedContinuation { continuation in
            pending[requestID] = continuation
            do {
                try stdinHandle.write(contentsOf: payload)
            } catch {
                if let cont = pending.removeValue(forKey: requestID) {
                    cont.resume(returning: "")
                }
                teardownWorker()
            }
        }
    }

    private func ensureWorkerRunning() -> Bool {
        if let process, process.isRunning {
            return true
        }
        teardownWorker()

        guard let executableURL = Bundle.main.executableURL else {
            return false
        }

        let proc = Process()
        proc.executableURL = executableURL
        proc.arguments = ["--ocr-worker"]

        let inPipe = Pipe()
        let outPipe = Pipe()
        proc.standardInput = inPipe
        proc.standardOutput = outPipe
        proc.standardError = FileHandle.nullDevice

        let readerHandle = outPipe.fileHandleForReading
        proc.terminationHandler = { [weak self] _ in
            Task {
                await self?.handleWorkerTerminated()
            }
        }

        do {
            try proc.run()
            process = proc
            stdinHandle = inPipe.fileHandleForWriting
            stdoutHandle = readerHandle
            readerTask = Task.detached(priority: .utility) { [weak self] in
                let decoder = JSONDecoder()
                do {
                    for try await line in readerHandle.bytes.lines {
                        guard !Task.isCancelled else { break }
                        guard let lineData = line.data(using: .utf8),
                              let resp = try? decoder.decode(OCRWorkerProcess.Response.self, from: lineData) else {
                            continue
                        }
                        await self?.fulfillResponse(id: resp.id, text: resp.text)
                    }
                } catch {
                    // 管道关闭或子进程退出
                }
                await self?.handleWorkerTerminated()
            }
            return true
        } catch {
            try? readerHandle.close()
            try? inPipe.fileHandleForWriting.close()
            return false
        }
    }

    private func fulfillResponse(id: String, text: String) {
        if let continuation = pending.removeValue(forKey: id) {
            continuation.resume(returning: text)
        }
    }

    private func handleWorkerTerminated() {
        teardownWorker()
    }

    private func teardownWorker() {
        readerTask?.cancel()
        readerTask = nil
        if let proc = process, proc.isRunning {
            proc.terminate()
        }
        try? stdinHandle?.close()
        try? stdoutHandle?.close()
        process = nil
        stdinHandle = nil
        stdoutHandle = nil

        let orphaned = pending
        pending.removeAll()
        for (_, continuation) in orphaned {
            continuation.resume(returning: "")
        }
    }
}
