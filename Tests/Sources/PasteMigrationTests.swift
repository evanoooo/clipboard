//
//  PasteMigrationTests.swift
//  Tests
//
//  Tests for Paste.app Migration (LZFSE, Deflate, Deduplication, and Schema mapping).
//

import AppKit
import Compression
import Foundation
import SQLite
import zlib

@MainActor
enum PasteMigrationTests {
    static func run(runner: TestRunner.Type) {
        print("\n--- Testing Paste Migration Algorithms & Deduplication ---")

        testLZFSEDecompression(runner: runner)
        testRawDeflateDecompression(runner: runner)
        testPayloadFormatParsing(runner: runner)
        testMigrationDeduplicationAndSorting(runner: runner)

        print("✓ Paste Migration tests passed!")
    }

    // MARK: - 1. LZFSE 解压缩测试

    private static func testLZFSEDecompression(runner: TestRunner.Type) {
        let originalText = "Paste LZFSE Compression Test Data - 剪贴板历史迁移算法测试 1234567890"
        let originalData = originalText.data(using: .utf8)!

        // 使用系统 Compression 压缩为 LZFSE
        var compressed = Data(count: originalData.count + 1024)
        let compressedCapacity = compressed.count
        let compressedSize = compressed.withUnsafeMutableBytes { dstBytes -> Int in
            originalData.withUnsafeBytes { srcBytes -> Int in
                guard let dstPtr = dstBytes.bindMemory(to: UInt8.self).baseAddress,
                      let srcPtr = srcBytes.bindMemory(to: UInt8.self).baseAddress else { return 0 }
                return compression_encode_buffer(dstPtr, compressedCapacity, srcPtr, originalData.count, nil, COMPRESSION_LZFSE)
            }
        }
        runner.assertTrue(compressedSize > 0, "LZFSE 压缩应当成功")
        compressed.count = compressedSize

        // 解压测试
        var decompressed = Data(count: originalData.count + 512)
        let decompressedCapacity = decompressed.count
        let decompressedSize = decompressed.withUnsafeMutableBytes { dstBytes -> Int in
            compressed.withUnsafeBytes { srcBytes -> Int in
                guard let dstPtr = dstBytes.bindMemory(to: UInt8.self).baseAddress,
                      let srcPtr = srcBytes.bindMemory(to: UInt8.self).baseAddress else { return 0 }
                return compression_decode_buffer(dstPtr, decompressedCapacity, srcPtr, compressed.count, nil, COMPRESSION_LZFSE)
            }
        }
        runner.assertTrue(decompressedSize == originalData.count, "LZFSE 解压大小应与原始一致")
        decompressed.count = decompressedSize
        runner.assertEqual(String(data: decompressed, encoding: .utf8), originalText, "LZFSE 解压文本内容必须完整一致")
    }

    // MARK: - 2. Raw DEFLATE 解压缩测试 (-MAX_WBITS)

    private static func testRawDeflateDecompression(runner: TestRunner.Type) {
        let originalText = "Paste Early Raw Deflate Stream JSON Payload {\"key\": \"value\"}"
        let originalData = originalText.data(using: .utf8)!

        // 构造 Raw Deflate
        var stream = z_stream()
        let initStatus = deflateInit2_(&stream, Z_DEFAULT_COMPRESSION, Z_DEFLATED, -MAX_WBITS, 8, Z_DEFAULT_STRATEGY, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size))
        runner.assertEqual(initStatus, Z_OK, "Raw deflateInit2_ 必须成功")

        var compressed = Data()
        let bufSize = 512
        var buffer = [UInt8](repeating: 0, count: bufSize)

        originalData.withUnsafeBytes { srcBytes in
            guard let srcPtr = srcBytes.bindMemory(to: UInt8.self).baseAddress else { return }
            stream.next_in = UnsafeMutablePointer(mutating: srcPtr)
            stream.avail_in = uInt(originalData.count)

            while true {
                buffer.withUnsafeMutableBytes { dstBytes in
                    guard let dstPtr = dstBytes.bindMemory(to: UInt8.self).baseAddress else { return }
                    stream.next_out = dstPtr
                    stream.avail_out = uInt(bufSize)
                    _ = deflate(&stream, Z_FINISH)
                    let produced = bufSize - Int(stream.avail_out)
                    if produced > 0 {
                        compressed.append(dstPtr, count: produced)
                    }
                }
                if stream.avail_out > 0 { break }
            }
        }
        deflateEnd(&stream)

        runner.assertTrue(!compressed.isEmpty, "Raw Deflate 压缩产物不应为空")

        // 解压测试
        var decompressStream = z_stream()
        let decompressInit = inflateInit2_(&decompressStream, -MAX_WBITS, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size))
        runner.assertEqual(decompressInit, Z_OK, "Raw inflateInit2_ 必须成功")

        var decompressed = Data()
        compressed.withUnsafeBytes { srcBytes in
            guard let srcPtr = srcBytes.bindMemory(to: UInt8.self).baseAddress else { return }
            decompressStream.next_in = UnsafeMutablePointer(mutating: srcPtr)
            decompressStream.avail_in = uInt(compressed.count)

            while decompressStream.avail_in > 0 {
                let ret = buffer.withUnsafeMutableBytes { dstBytes -> Int32 in
                    guard let dstPtr = dstBytes.bindMemory(to: UInt8.self).baseAddress else { return Z_DATA_ERROR }
                    decompressStream.next_out = dstPtr
                    decompressStream.avail_out = uInt(bufSize)
                    let err = inflate(&decompressStream, Z_NO_FLUSH)
                    let produced = bufSize - Int(decompressStream.avail_out)
                    if produced > 0 {
                        decompressed.append(dstPtr, count: produced)
                    }
                    return err
                }
                if ret == Z_STREAM_END { break }
            }
        }
        inflateEnd(&decompressStream)

        runner.assertEqual(String(data: decompressed, encoding: .utf8), originalText, "Raw Deflate 解压结果必须与原文一致")
    }

    // MARK: - 3. Payload 格式与 bplist 解析测试

    private static func testPayloadFormatParsing(runner: TestRunner.Type) {
        let sampleDict: [String: Any] = [
            "dataByType": [
                "public.utf8-plain-text": "Hello, Paste Migration!".data(using: .utf8)!
            ]
        ]
        let plistData = try! PropertyListSerialization.data(fromPropertyList: [sampleDict], format: .binary, options: 0)

        // 构造带 0x01 marker 的未压缩 bplist payload
        var payload = Data([0x01])
        payload.append(plistData)

        runner.assertEqual(payload[0], 0x01, "Marker 必须为 0x01")
        let innerData = payload.subdata(in: 1..<payload.count)
        runner.assertTrue(innerData.starts(with: "bplist".utf8), "内部数据应以 bplist 标识开头")

        let deserialized = try! PropertyListSerialization.propertyList(from: innerData, options: [], format: nil) as? [[String: Any]]
        runner.assertTrue(deserialized != nil, "反序列化必须成功")
        let item = deserialized!.first!
        let dataByType = item["dataByType"] as? [String: Any]
        runner.assertTrue(dataByType != nil, "必须包含 dataByType")
        let utf8Data = dataByType!["public.utf8-plain-text"] as? Data
        runner.assertEqual(String(data: utf8Data!, encoding: .utf8), "Hello, Paste Migration!", "提取出的文本必须一致")
    }

    // MARK: - 4. 数据库迁移去重与时间线重排序测试

    private static func testMigrationDeduplicationAndSorting(runner: TestRunner.Type) {
        do {
            let destDb = try Connection(.inMemory)

            // 创建目标表
            try destDb.execute("""
            CREATE TABLE Clip (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                unique_id TEXT NOT NULL,
                type TEXT NOT NULL,
                data BLOB NOT NULL,
                show_data BLOB,
                timestamp INTEGER NOT NULL,
                sort_order INTEGER DEFAULT 0,
                app_id INTEGER NOT NULL,
                search_text TEXT NOT NULL,
                length INTEGER NOT NULL,
                "group" INTEGER DEFAULT -1,
                tag TEXT,
                alias TEXT,
                alias_search TEXT,
                hidden INTEGER DEFAULT 0
            );
            CREATE UNIQUE INDEX uidx_unique_id ON Clip(unique_id);
            """)

            // 预先插入一条现有记录 (用户修改过其标签并收藏置顶)
            let existingUniqueId = "hash_existing_record"
            try destDb.execute("""
            INSERT INTO Clip (unique_id, type, data, timestamp, sort_order, app_id, search_text, length, "group", tag)
            VALUES ('\(existingUniqueId)', 'public.utf8-plain-text', X'616263', 1700000000, 10, 1, '既存内容', 4, 1, 'work');
            """)

            // 模拟 Paste 迁移输入两条记录：一条重复，一条全新
            let recordsToMigrate: [(uniqueId: String, text: String, timestamp: Int64)] = [
                (existingUniqueId, "既存内容重复项", 1690000000), // 重复项，时间戳更早
                ("hash_new_record_2022", "2022年的老历史", 1650000000), // 新项，老历史
                ("hash_new_record_2024", "2024年的新历史", 1720000000)  // 新项，新历史
            ]

            var imported = 0
            var duplicates = 0

            for r in recordsToMigrate {
                let count = try destDb.scalar("SELECT COUNT(*) FROM Clip WHERE unique_id = ?", r.uniqueId) as? Int64 ?? 0
                if count > 0 {
                    duplicates += 1
                } else {
                    try destDb.execute("""
                    INSERT INTO Clip (unique_id, type, data, timestamp, sort_order, app_id, search_text, length)
                    VALUES ('\(r.uniqueId)', 'public.utf8-plain-text', X'61', \(r.timestamp), 0, 1, '\(r.text)', 2);
                    """)
                    imported += 1
                }
            }

            runner.assertEqual(imported, 2, "应成功导入 2 条全新记录")
            runner.assertEqual(duplicates, 1, "应准确识别并跳过 1 条重复记录")

            // 验证既存记录的内容和用户标记完好无损
            let existingRow = try destDb.prepare("SELECT \"group\", tag, search_text FROM Clip WHERE unique_id = ?", existingUniqueId).map { $0 }.first!
            runner.assertEqual(existingRow[0] as? Int64, 1, "已有记录的分组收藏绝不能被覆盖")
            runner.assertEqual(existingRow[1] as? String, "work", "已有记录的用户自定义标签绝不能被覆盖")
            runner.assertEqual(existingRow[2] as? String, "既存内容", "已有记录的内容绝不能被覆盖")

            // 执行时间线重排序算法 (ROW_NUMBER rank)
            try destDb.execute("""
            WITH ranks AS (
                SELECT id, ROW_NUMBER() OVER (ORDER BY timestamp ASC, id ASC) AS rank
                FROM Clip
            )
            UPDATE Clip SET sort_order = (SELECT rank FROM ranks WHERE ranks.id = Clip.id);
            """)

            // 验证排序：按 sort_order 倒序输出 (即最新记录在前)
            let ordered = try destDb.prepare("SELECT search_text, timestamp, sort_order FROM Clip ORDER BY sort_order DESC").map {
                ($0[0] as! String, $0[1] as! Int64, $0[2] as! Int64)
            }

            runner.assertEqual(ordered.count, 3, "总共应有 3 条记录")
            // 2024年新记录 (1720000000) 应排在最前 (rank 3)
            runner.assertEqual(ordered[0].0, "2024年的新历史", "时间最新的记录必须排在第一位")
            runner.assertEqual(ordered[0].2, 3, "最新记录的 sort_order 必须最大")

            // 既存记录 (1700000000) 排在第二 (rank 2)
            runner.assertEqual(ordered[1].0, "既存内容", "中间时间的记录排在第二位")
            runner.assertEqual(ordered[1].2, 2, "中间记录的 sort_order 应为 2")

            // 2022年老历史 (1650000000) 排在最后 (rank 1)
            runner.assertEqual(ordered[2].0, "2022年的老历史", "历史最旧记录排在最后")
            runner.assertEqual(ordered[2].2, 1, "历史最旧记录的 sort_order 应为 1")

        } catch {
            runner.assertTrue(false, "数据库迁移测试失败：\(error)")
        }
    }
}
