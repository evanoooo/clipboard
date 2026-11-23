//
//  SyncByteBudgetLimiter.swift
//  Clipboard
//
//  云同步在途字节预算限流器与载荷体积估算工具
//

import Foundation

/// 云同步在途字节预算限流器：控制在途并发内存占用上限（默认 24MB），单条超大对象自动退化为独占串行处理
actor SyncByteBudgetLimiter {
    private let maxBudgetBytes: Int
    private var inFlightBytes: Int = 0
    private var inFlightCount: Int = 0
    private var waiters: [(requestedBytes: Int, continuation: CheckedContinuation<Int, Never>)] = []

    init(maxBudgetBytes: Int = 24 * 1024 * 1024) {
        self.maxBudgetBytes = maxBudgetBytes
    }

    func acquire(estimatedBytes: Int) async -> Int {
        let cost = max(estimatedBytes, 64 * 1024)
        if inFlightCount == 0 || (inFlightBytes + cost <= maxBudgetBytes) {
            inFlightBytes += cost
            inFlightCount += 1
            return cost
        }
        return await withCheckedContinuation { continuation in
            waiters.append((cost, continuation))
        }
    }

    func release(acquiredBytes: Int) {
        inFlightBytes = max(0, inFlightBytes - acquiredBytes)
        inFlightCount = max(0, inFlightCount - 1)
        drainWaiters()
    }

    private func drainWaiters() {
        while let first = waiters.first {
            if inFlightCount == 0 || (inFlightBytes + first.requestedBytes <= maxBudgetBytes) {
                waiters.removeFirst()
                inFlightBytes += first.requestedBytes
                inFlightCount += 1
                first.continuation.resume(returning: first.requestedBytes)
            } else {
                break
            }
        }
    }
}

extension SyncEngine {
    nonisolated static func estimatedDownloadBytes(id: String, entry: SyncIndexEntry?) -> Int {
        if let size = entry?.size, size > 0 {
            return size
        }
        if id.contains("-"), let tail = id.split(separator: "-").last, let exactBytes = Int(tail), exactBytes > 0 {
            return exactBytes
        }
        return 512 * 1024
    }

    nonisolated static func estimatedUploadBytes(for blob: SyncItemBlob) -> Int {
        if let payloadCount = blob.payloadData?.count, payloadCount > 0 {
            return payloadCount + (blob.showData?.count ?? 0)
        }
        if blob.uniqueId.contains("-"),
           let tail = blob.uniqueId.split(separator: "-").last,
           let exactBytes = Int(tail),
           exactBytes > 0 {
            return exactBytes
        }
        return 512 * 1024
    }
}
