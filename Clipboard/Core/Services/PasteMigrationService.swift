//
//  PasteMigrationService.swift
//  Clipboard
//
//  Created by crown on 2026/10/23.
//

import AppKit
import Compression
import Foundation
import SQLite
import zlib

/// Paste.app 历史数据迁移服务 (Actor 保证线程安全)
actor PasteMigrationService {
    public static let shared = PasteMigrationService()

    private let coreDataEpochOffset: Double = 978307200.0 // 2001-01-01 相对 1970-01-01 差值 (秒)
    private var isMigrating = false

    private init() {}

    // MARK: - 默认数据库探测

    /// 检测系统默认路径下的 Paste.app 数据库
    public nonisolated func detectDefaultDatabase() -> URL? {
        let defaultURL = URL.homeDirectory
            .appending(path: "Library/Application Support/Paste/db.sqlite")
        return FileManager.default.fileExists(atPath: defaultURL.path) ? defaultURL : nil
    }

    // MARK: - 数据库预检扫描

    /// 扫描指定的 Paste.app 数据库文件，提取统计摘要
    public func scan(databaseURL: URL) async throws -> PasteMigrationScanInfo {
        guard FileManager.default.fileExists(atPath: databaseURL.path) else {
            throw NSError(
                domain: "PasteMigration",
                code: 404,
                userInfo: [NSLocalizedDescriptionKey: "找不到指定的 Paste.app 数据库文件"]
            )
        }

        let size = (try? FileManager.default.attributesOfItem(atPath: databaseURL.path)[.size] as? Int64) ?? 0

        // 使用只读安全连接扫描
        let db = try Connection(databaseURL.path, readonly: true)
        db.busyTimeout = 5.0

        let itemCount = try db.scalar(
            "SELECT COUNT(*) FROM ZITEMENTITY WHERE ZDATA IS NOT NULL"
        ) as? Int64 ?? 0

        let appCount = try db.scalar(
            "SELECT COUNT(*) FROM ZAPPLICATIONENTITY"
        ) as? Int64 ?? 0

        var earliestDate: Date?
        var latestDate: Date?

        let rows = try db.prepare(
            "SELECT MIN(ZCREATEDAT), MAX(ZCREATEDAT) FROM ZITEMENTITY WHERE ZCREATEDAT IS NOT NULL"
        )
        for row in rows {
            if let minVal = row[0] as? Double {
                earliestDate = Date(timeIntervalSinceReferenceDate: minVal)
            }
            if let maxVal = row[1] as? Double {
                latestDate = Date(timeIntervalSinceReferenceDate: maxVal)
            }
        }

        return PasteMigrationScanInfo(
            databaseURL: databaseURL,
            totalItemCount: Int(itemCount),
            sourceAppCount: Int(appCount),
            earliestDate: earliestDate,
            latestDate: latestDate,
            databaseSizeBytes: size
        )
    }

    // MARK: - 自动备份快照

    /// 在迁移修改前创建生产数据库的安全快照
    public func createBackupSnapshot() throws -> URL {
        let sourcePath = PasteSQLManager.databasePath
        guard FileManager.default.fileExists(atPath: sourcePath) else {
            throw NSError(
                domain: "PasteMigration",
                code: 404,
                userInfo: [NSLocalizedDescriptionKey: "目标 Clipboard 数据库尚不存在"]
            )
        }

        let backupDir = URL.documentsDirectory.appending(path: "Clip/AutoBackup")
        try FileManager.default.createDirectory(at: backupDir, withIntermediateDirectories: true)

        let timestamp = Date.now.formatted(
            .iso8601
                .year()
                .month()
                .day()
                .dateSeparator(.omitted)
                .time(includingFractionalSeconds: false)
                .timeSeparator(.omitted)
        )
        let backupURL = backupDir.appending(path: "Clip_AutoBackup_\(timestamp).sqlite3")

        let sourceDb = try Connection(sourcePath, readonly: true)
        let destDb = try Connection(backupURL.path)
        let backup = try sourceDb.backup(usingConnection: destDb)
        try backup.step()

        log.info("已生成迁移前安全快照备份: \(backupURL.path)")
        return backupURL
    }

    // MARK: - 数据迁移执行

    /// 执行从 Paste 数据库向 Clipboard 数据库的迁移
    public func migrate(
        from sourceURL: URL,
        progress: (@Sendable (PasteMigrationProgress) -> Void)? = nil
    ) async throws -> PasteMigrationResult {
        guard !isMigrating else {
            throw NSError(
                domain: "PasteMigration",
                code: 409,
                userInfo: [NSLocalizedDescriptionKey: "已有正在进行的迁移任务"]
            )
        }

        isMigrating = true
        defer { isMigrating = false }

        // 1. 创建安全快照
        let backupURL = try createBackupSnapshot()

        // 2. 外部大文件目录
        let externalDir = sourceURL.deletingLastPathComponent()
            .appending(path: ".db_SUPPORT/_EXTERNAL_DATA")
        let hasExternalDir = FileManager.default.fileExists(atPath: externalDir.path)

        // 3. 打开连接
        let srcDb = try Connection(sourceURL.path, readonly: true)
        srcDb.busyTimeout = 10.0

        let destPath = PasteSQLManager.databasePath
        let destDb = try Connection(destPath)
        destDb.busyTimeout = 10.0

        // 4. 映射来源应用
        progress?(PasteMigrationProgress(
            current: 0, total: 1, importedCount: 0, duplicateCount: 0, skippedCount: 0,
            statusMessage: "正在解析来源应用..."
        ))

        let appIdMapping = try mapSourceApplications(from: srcDb, into: destDb)

        let fallbackAppId: Int64
        if let existing = try destDb.scalar("SELECT id FROM App WHERE bundle_id = 'com.apple.finder'") as? Int64 {
            fallbackAppId = existing
        } else {
            let insert = "INSERT INTO App (bundle_id, app_name, app_path) VALUES ('com.apple.finder', 'Finder', '/System/Library/CoreServices/Finder.app')"
            try destDb.execute(insert)
            fallbackAppId = destDb.lastInsertRowid
        }

        // 5. 查询总待迁移数据
        let totalCount = try srcDb.scalar(
            "SELECT COUNT(*) FROM ZITEMENTITY i LEFT JOIN ZITEMDATAENTITY d ON i.ZDATA = d.Z_PK WHERE d.ZRAWPASTEBOARDITEMS IS NOT NULL"
        ) as? Int64 ?? 0

        guard totalCount > 0 else {
            return PasteMigrationResult(
                isSuccess: true,
                importedCount: 0,
                duplicateCount: 0,
                skippedCount: 0,
                autoBackupURL: backupURL
            )
        }

        let query = """
        SELECT i.Z_PK, i.ZRAWTYPE, i.ZSOURCEAPPLICATION, i.ZCREATEDAT, i.ZTITLE,
               d.ZRAWPASTEBOARDITEMS
        FROM ZITEMENTITY i
        LEFT JOIN ZITEMDATAENTITY d ON i.ZDATA = d.Z_PK
        WHERE d.ZRAWPASTEBOARDITEMS IS NOT NULL
        ORDER BY i.Z_PK ASC
        """
        let rows = try srcDb.prepare(query)

        var importedCount = 0
        var duplicateCount = 0
        var skippedCount = 0
        var processedCount = 0
        let batchSize = 200

        try destDb.execute("BEGIN IMMEDIATE TRANSACTION;")

        do {
            for row in rows {
                processedCount += 1

                let rawCreatedAt = row[3] as? Double ?? 0.0
                let timestamp = Int64(rawCreatedAt + coreDataEpochOffset)
                let sourceAppPK = row[2] as? Int64 ?? -1
                let appId = appIdMapping[sourceAppPK] ?? fallbackAppId
                let title = row[4] as? String
                guard let blob = row[5] as? Blob else {
                    skippedCount += 1
                    continue
                }

                let blobData = Data(blob.bytes)
                guard let parsed = parsePastePayload(blob: blobData, externalDir: hasExternalDir ? externalDir : nil) else {
                    skippedCount += 1
                    continue
                }

                guard let extracted = extractContent(from: parsed, title: title) else {
                    skippedCount += 1
                    continue
                }

                let uniqueId = await PasteboardModel.generateUniqueId(for: extracted.type, data: extracted.data)

                // 去重检查 (基于 unique_id)
                let existing = try destDb.scalar(
                    "SELECT COUNT(*) FROM Clip WHERE unique_id = ?", uniqueId
                ) as? Int64 ?? 0

                if existing > 0 {
                    duplicateCount += 1
                } else {
                    let insertStmt = """
                    INSERT INTO Clip (
                        unique_id, type, data, show_data, timestamp, sort_order,
                        app_id, search_text, length, "group", tag, alias, alias_search, hidden
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, -1, ?, NULL, NULL, 0)
                    """
                    try destDb.run(
                        insertStmt,
                        uniqueId,
                        extracted.type.rawValue,
                        extracted.data.datatypeValue,
                        extracted.showData?.datatypeValue,
                        timestamp,
                        0, // 稍后全量基于真实时间线统一重序
                        appId,
                        extracted.searchText,
                        extracted.length,
                        extracted.tag
                    )
                    importedCount += 1
                }

                // 批处理提交与进度通知
                if processedCount % batchSize == 0 {
                    try destDb.execute("COMMIT;")
                    try destDb.execute("BEGIN IMMEDIATE TRANSACTION;")

                    progress?(PasteMigrationProgress(
                        current: processedCount,
                        total: Int(totalCount),
                        importedCount: importedCount,
                        duplicateCount: duplicateCount,
                        skippedCount: skippedCount,
                        statusMessage: "正在迁移第 \(processedCount) / \(totalCount) 条..."
                    ))
                }
            }

            try destDb.execute("COMMIT;")
        } catch {
            _ = try? destDb.execute("ROLLBACK;")
            throw error
        }

        // 6. 重建时间线顺序 (sort_order 按 timestamp 升序赋 rank)
        progress?(PasteMigrationProgress(
            current: Int(totalCount),
            total: Int(totalCount),
            importedCount: importedCount,
            duplicateCount: duplicateCount,
            skippedCount: skippedCount,
            statusMessage: "正在重建时间线并优化索引..."
        ))

        try destDb.transaction(.immediate) {
            try destDb.execute("""
            WITH ranks AS (
                SELECT id, ROW_NUMBER() OVER (ORDER BY timestamp ASC, id ASC) AS rank
                FROM Clip
            )
            UPDATE Clip SET sort_order = (SELECT rank FROM ranks WHERE ranks.id = Clip.id);
            """)
        }

        // 7. 刷新缓存与状态
        try? await PasteSQLManager.manager.loadApps()
        let records = await PasteSQLManager.manager.getDistinctAppInfo()
        await MainActor.run {
            ClipUndoStore.shared.removeAll()
            SourceAppCache.shared.replace(records)
            SourceAppCache.shared.warmMissingIcons()
            AppColorService.shared.fillMissingColors()
        }
        await PasteDataStore.main.resetDefaultList()

        return PasteMigrationResult(
            isSuccess: true,
            importedCount: importedCount,
            duplicateCount: duplicateCount,
            skippedCount: skippedCount,
            autoBackupURL: backupURL
        )
    }

    // MARK: - 应用字典映射

    private func mapSourceApplications(from srcDb: Connection, into destDb: Connection) throws -> [Int64: Int64] {
        var mapping: [Int64: Int64] = [:]
        let rows = try srcDb.prepare("SELECT Z_PK, ZNAME, ZBUNDLEIDENTIFIER, ZRAWICON FROM ZAPPLICATIONENTITY")

        for row in rows {
            let pk = row[0] as? Int64 ?? 0
            let name = (row[1] as? String) ?? "Unknown"
            let bundleId = row[2] as? String
            let iconBlob = row[3] as? Blob
            let iconData = iconBlob.map { Data($0.bytes) }
            let appPath = "/Applications/\(name).app"

            let appID = try SourceAppSQL.resolve(
                name: name,
                path: appPath,
                bundleID: bundleId,
                iconData: iconData,
                on: destDb
            )
            mapping[pk] = appID
        }

        return mapping
    }

    // MARK: - 解包与解压算法 (LZFSE, Raw DEFLATE, Zlib, bplist, JSON)

    private func parsePastePayload(blob: Data, externalDir: URL?) -> Any? {
        guard blob.count >= 2 else { return nil }

        let marker = blob[blob.startIndex]
        let payload = blob.subdata(in: (blob.startIndex + 1)..<blob.endIndex)

        // 1. 外部大文件引用 (0x02 + UUID)
        if marker == 0x02, let externalDir {
            if let uuidStr = String(data: payload, encoding: .ascii)?.trimmingCharacters(in: .whitespacesAndNewlines) {
                let fileURL = externalDir.appending(path: uuidStr)
                if let fileData = try? Data(contentsOf: fileURL) {
                    if let plist = parsePlist(from: fileData) { return plist }
                    if let json = parseJSON(from: fileData) { return json }
                }
            }
        }

        // 2. 内联数据 (0x01)
        if marker == 0x01 {
            // A) 检查是否为 LZFSE (以 'bvxn' 开头: 0x62, 0x76, 0x78, 0x6E)
            if payload.starts(with: [0x62, 0x76, 0x78, 0x6E]) {
                if let decompressed = decompressLZFSE(data: payload) {
                    if let plist = parsePlist(from: decompressed) { return plist }
                    if let json = parseJSON(from: decompressed) { return json }
                }
            }

            // B) 尝试 Raw DEFLATE (-MAX_WBITS)
            if let decompressed = decompressDeflate(data: payload, windowBits: -MAX_WBITS) {
                if let plist = parsePlist(from: decompressed) { return plist }
                if let json = parseJSON(from: decompressed) { return json }
            }

            // C) 尝试标准 ZLIB (MAX_WBITS)
            if let decompressed = decompressDeflate(data: payload, windowBits: MAX_WBITS) {
                if let plist = parsePlist(from: decompressed) { return plist }
                if let json = parseJSON(from: decompressed) { return json }
            }

            // D) 尝试未压缩 bplist
            if payload.starts(with: "bplist".utf8) {
                if let plist = parsePlist(from: payload) { return plist }
            }

            // E) 尝试纯 JSON
            if payload.starts(with: "[".utf8) || payload.starts(with: "{".utf8) {
                if let json = parseJSON(from: payload) { return json }
            }
        }

        return nil
    }

    private func parsePlist(from data: Data) -> Any? {
        try? PropertyListSerialization.propertyList(from: data, options: [], format: nil)
    }

    private func parseJSON(from data: Data) -> Any? {
        try? JSONSerialization.jsonObject(with: data, options: [])
    }

    // MARK: - 原生 LZFSE 解压 (系统 libcompression)

    private func decompressLZFSE(data: Data) -> Data? {
        guard !data.isEmpty else { return nil }

        let expansionFactors = [15, 40, 100, 200]
        for factor in expansionFactors {
            let capacity = max(data.count * factor + 1024 * 1024, 2 * 1024 * 1024)
            var destination = Data(count: capacity)

            let decodedSize = destination.withUnsafeMutableBytes { destBytes -> Int in
                data.withUnsafeBytes { srcBytes -> Int in
                    guard let destPtr = destBytes.bindMemory(to: UInt8.self).baseAddress,
                          let srcPtr = srcBytes.bindMemory(to: UInt8.self).baseAddress else { return 0 }
                    return compression_decode_buffer(
                        destPtr,
                        capacity,
                        srcPtr,
                        data.count,
                        nil,
                        COMPRESSION_LZFSE
                    )
                }
            }

            if decodedSize > 0 {
                destination.count = decodedSize
                return destination
            }
        }
        return nil
    }

    // MARK: - 原生 Deflate/Zlib 解压 (系统 libz)

    private func decompressDeflate(data: Data, windowBits: Int32) -> Data? {
        guard !data.isEmpty else { return nil }

        var stream = z_stream()
        let status = inflateInit2_(&stream, windowBits, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size))
        guard status == Z_OK else { return nil }
        defer { inflateEnd(&stream) }

        var decompressed = Data()
        let bufferSize = 64 * 1024
        var buffer = [UInt8](repeating: 0, count: bufferSize)

        return data.withUnsafeBytes { srcBytes in
            guard let srcPtr = srcBytes.bindMemory(to: UInt8.self).baseAddress else { return nil }
            stream.next_in = UnsafeMutablePointer(mutating: srcPtr)
            stream.avail_in = uInt(data.count)

            while stream.avail_in > 0 {
                let ret: Int32 = buffer.withUnsafeMutableBytes { bufBytes in
                    guard let bufPtr = bufBytes.bindMemory(to: UInt8.self).baseAddress else { return Z_DATA_ERROR }
                    stream.next_out = bufPtr
                    stream.avail_out = uInt(bufferSize)
                    let err = inflate(&stream, Z_NO_FLUSH)
                    let produced = bufferSize - Int(stream.avail_out)
                    if produced > 0 {
                        decompressed.append(bufPtr, count: produced)
                    }
                    return err
                }

                if ret == Z_STREAM_END {
                    break
                } else if ret != Z_OK {
                    return nil
                }
            }
            return decompressed
        }
    }

    // MARK: - 内容提取与标准化

    private struct ExtractedClip {
        let type: PasteboardType
        let data: Data
        let showData: Data?
        let searchText: String
        let length: Int
        let tag: String
    }

    private func extractContent(from parsed: Any, title: String?) -> ExtractedClip? {
        var rawDict: [String: Any]?

        if let array = parsed as? [[String: Any]], let first = array.first {
            rawDict = first
        } else if let dict = parsed as? [String: Any] {
            rawDict = dict
        }

        guard let dict = rawDict, let dataByType = dict["dataByType"] as? [String: Any] else {
            return nil
        }

        // 标准化字节表
        var byteMap: [String: Data] = [:]
        for (uti, val) in dataByType {
            if let data = val as? Data {
                byteMap[uti] = data
            } else if let str = val as? String {
                if let decoded = Data(base64Encoded: str) {
                    byteMap[uti] = decoded
                } else if let utf8 = str.data(using: .utf8) {
                    byteMap[uti] = utf8
                }
            }
        }

        guard !byteMap.isEmpty else { return nil }

        // 1. 优先纯文本
        if let textData = byteMap["public.utf8-plain-text"] ?? byteMap["public.text"] {
            let str = String(data: textData, encoding: .utf8) ?? ""
            let tag = PasteboardModel.calculateTextTag(str)
            let previewPrefix = String(str.prefix(300))
            let showData = previewPrefix.data(using: .utf8)
            return ExtractedClip(
                type: .string,
                data: textData,
                showData: showData,
                searchText: str,
                length: str.count,
                tag: tag
            )
        }

        // 2. 富文本
        if let rtfData = byteMap["public.rtf"] {
            let str = title ?? "富文本"
            return ExtractedClip(
                type: .rtf,
                data: rtfData,
                showData: nil,
                searchText: str,
                length: str.count,
                tag: "rich"
            )
        }

        // 3. 图片 (PNG / TIFF / JPEG)
        if let pngData = byteMap["public.png"] {
            return ExtractedClip(
                type: .png,
                data: pngData,
                showData: nil,
                searchText: title ?? "图片",
                length: pngData.count,
                tag: "image"
            )
        }
        if let tiffData = byteMap["public.tiff"] {
            return ExtractedClip(
                type: .tiff,
                data: tiffData,
                showData: nil,
                searchText: title ?? "图片",
                length: tiffData.count,
                tag: "image"
            )
        }
        if let jpegData = byteMap["public.jpeg"] {
            return ExtractedClip(
                type: .png,
                data: jpegData,
                showData: nil,
                searchText: title ?? "图片",
                length: jpegData.count,
                tag: "image"
            )
        }

        // 4. 文件 URL
        if let fileData = byteMap["public.file-url"] {
            let str = String(data: fileData, encoding: .utf8) ?? (title ?? "文件")
            return ExtractedClip(
                type: .fileURL,
                data: fileData,
                showData: nil,
                searchText: str,
                length: str.count,
                tag: "file"
            )
        }

        // 5. 兜底首个有效类型
        if let (uti, firstData) = byteMap.first {
            let type = PasteboardType(uti)
            let str = title ?? uti
            return ExtractedClip(
                type: type,
                data: firstData,
                showData: nil,
                searchText: str,
                length: firstData.count,
                tag: ""
            )
        }

        return nil
    }
}
