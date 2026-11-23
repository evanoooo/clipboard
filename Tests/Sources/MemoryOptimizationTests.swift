//
//  MemoryOptimizationTests.swift
//  Tests
//
//  验证有界内存缓存、惰性计算与微秒级点查
//

import AppKit
import Foundation
import os
import SQLite

enum MemoryOptimizationTests {
    @MainActor
    static func runAll() {
        print("\n--- Testing Bounded Memory Caches & Runtime Optimizations ---")
        testThumbnailCache()
        testAttributedTextCache()
        testLinkMetadataCache()
        testSensitiveCredentialCheck()
        testImageDownsampler()
        testSearchTextCapping()
        testInlineSmallDataSQL()
        testClipStoreEventBus()
        testColorToHexString()
        print("✓ Bounded Memory Caches & Runtime Optimizations tests passed!")
    }

    private static func testImageDownsampler() {
        // 创建一个简单的 100x100 位图数据
        let image = NSImage(size: NSSize(width: 100, height: 100))
        image.lockFocus()
        NSColor.red.drawSwatch(in: NSRect(x: 0, y: 0, width: 100, height: 100))
        image.unlockFocus()

        guard let tiffData = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiffData),
              let pngData = rep.representation(using: .png, properties: [:]) else {
            assertionFailure("Failed to create PNG test data")
            return
        }

        let downsampled = ImageDownsampler.downsampleNSImage(from: pngData, maxPixelSize: 50)
        assert(downsampled != nil, "Downsampling should succeed")
        assert(downsampled!.size.width <= 50, "Downsampled width should not exceed 50")
        assert(downsampled!.size.height <= 50, "Downsampled height should not exceed 50")

        let thumbData = ImageDownsampler.generateThumbnailData(from: pngData, maxPixelSize: 40)
        assert(thumbData != nil && !thumbData!.isEmpty, "Thumbnail data generation should succeed")
    }

    private static func testSearchTextCapping() {
        let longText = String(repeating: "剪贴板全文搜索测试", count: 1000) // ~9000 字符
        let normalized = SearchTextNormalizer.normalize(longText)
        let capped = SearchTextNormalizer.capForListModel(normalized)
        assert(capped.count == 2000, "Search text in list models must be capped to 2000 chars")
        assert(SearchTextNormalizer.capForListModel("short") == "short", "Short text must remain intact")
        assert(SearchTextNormalizer.capForListModel(nil).isEmpty, "Nil text must return empty string")
    }

    private static func testInlineSmallDataSQL() {
        do {
            let db = try MemoryDatabaseHelper.createInMemoryDatabase()
            let table = MemoryDatabaseHelper.clipTable

            let smallPayload = Data(repeating: 0x41, count: 1024) // 1KB <= 4096
            let largePayload = Data(repeating: 0x42, count: 8192) // 8KB > 4096

            try db.run(table.insert(
                Col.uniqueId <- "small_uid",
                Col.type <- "public.utf8-plain-text",
                Col.data <- smallPayload,
                Col.showData <- smallPayload,
                Col.timestamp <- 100,
                Col.appID <- 1,
                Col.searchText <- "small",
                Col.length <- 1024,
                Col.group <- -1,
                Col.tag <- "string"
            ))

            try db.run(table.insert(
                Col.uniqueId <- "large_uid",
                Col.type <- "public.png",
                Col.data <- largePayload,
                Col.showData <- smallPayload,
                Col.timestamp <- 200,
                Col.appID <- 1,
                Col.searchText <- "",
                Col.length <- 8192,
                Col.group <- -1,
                Col.tag <- "image"
            ))

            let rows = Array(try db.prepare(
                table.select(Col.uniqueId, Col.inlineData).order(Col.timestamp.asc)
            ))
            assert(rows.count == 2, "Should retrieve 2 rows")
            let smallInline = try rows[0].get(Col.inlineData)
            let largeInline = try rows[1].get(Col.inlineData)
            assert(smallInline == smallPayload, "Payload <= 4KB must be returned inline without secondary point read")
            assert(largeInline == nil, "Payload > 4KB must return nil in list query to avoid memory bloat")
        } catch {
            assertionFailure("testInlineSmallDataSQL failed: \(error)")
        }
    }

    private static func testThumbnailCache() {
        let cache = ModelThumbnailCache.shared
        cache.removeAll()

        let image = NSImage(size: NSSize(width: 100, height: 100))
        cache.setThumbnail(image, for: "uid_1")

        assert(cache.thumbnail(for: "uid_1") != nil, "Thumbnail should be retrievable from cache")
        assert(cache.thumbnail(for: "uid_2") == nil, "Non-existent thumbnail should return nil")

        cache.remove(for: "uid_1")
        assert(cache.thumbnail(for: "uid_1") == nil, "Removed thumbnail should be nil")

        cache.setThumbnail(image, for: "uid_1")
        cache.removeAll()
        assert(cache.thumbnail(for: "uid_1") == nil, "removeAll should evict all thumbnails")
    }

    private static func testAttributedTextCache() {
        let cache = ModelAttributedTextCache.shared
        cache.removeAll()

        let text = NSAttributedString(string: "Hello world code snippet")
        cache.setText(text, for: "code:123")

        let retrieved = cache.text(for: "code:123")
        assert(retrieved?.string == "Hello world code snippet", "Attributed text should match")

        cache.remove(for: "code:123")
        assert(cache.text(for: "code:123") == nil, "Removed text should be nil")
    }

    private static func testLinkMetadataCache() {
        let cache = ModelLinkMetadataCache.shared
        cache.removeAll()

        let meta = LinkPreviewMetadata(
            title: "Apple Developer",
            previewImage: NSImage(size: NSSize(width: 200, height: 200)),
            iconImage: nil
        )
        cache.setMetadata(meta, for: "https://developer.apple.com")

        let retrieved = cache.metadata(for: "https://developer.apple.com")
        assert(retrieved?.title == "Apple Developer", "Link metadata title should match")

        cache.removeAll()
        assert(cache.metadata(for: "https://developer.apple.com") == nil, "removeAll should evict link metadata")
    }

    private static func testSensitiveCredentialCheck() {
        let normalText = "This is a normal clipboard text without any credential."
        assert(PasteboardContentFilter.detectSensitiveCredential(in: normalText) == nil)

        let privateKey = "-----BEGIN RSA PRIVATE KEY-----\nMIIEowIBAAKCAQEA..."
        assert(PasteboardContentFilter.detectSensitiveCredential(in: privateKey) != nil)

        let awsKey = "AKIAIOSFODNN7EXAMPLE"
        assert(PasteboardContentFilter.detectSensitiveCredential(in: awsKey) != nil)

        let githubToken = "ghp_1234567890abcdefghijklmnopqrstuvwxyz"
        assert(PasteboardContentFilter.detectSensitiveCredential(in: githubToken) != nil)
    }

    @MainActor
    private static func testClipStoreEventBus() {
        let received = OSAllocatedUnfairLock<[ClipStoreEvent]>(initialState: [])
        let token = UUID().uuidString
        let deletedUid = "\(token)-deleted"
        let updatedUid = "\(token)-updated"

        ClipStoreEventBus.shared.subscribe { event in
            received.withLock { $0.append(event) }
        }

        ClipStoreEventBus.shared.publish(.itemsDeleted(uniqueIds: [deletedUid], hotIds: [101, 202]))
        ClipStoreEventBus.shared.publish(.itemGroupUpdated(uniqueId: updatedUid, groupId: 7))

        let matching = received.withLock { events -> [ClipStoreEvent] in
            events.filter { event in
                switch event {
                case .itemsDeleted(let uniqueIds, _):
                    return uniqueIds == [deletedUid]
                case .itemGroupUpdated(let uniqueId, _):
                    return uniqueId == updatedUid
                }
            }
        }

        TestRunner.assertEqual(matching.count, 2, "ClipStoreEventBus should deliver both published events")
        if matching.count == 2 {
            if case .itemsDeleted(let uniqueIds, let hotIds) = matching[0] {
                TestRunner.assertEqual(uniqueIds, [deletedUid], "First event should preserve deleted uniqueIds")
                TestRunner.assertEqual(hotIds, [101, 202], "First event should preserve hotIds")
            } else {
                TestRunner.assertTrue(false, "First event should be .itemsDeleted")
            }
            if case .itemGroupUpdated(let uniqueId, let groupId) = matching[1] {
                TestRunner.assertEqual(uniqueId, updatedUid, "Second event should preserve uniqueId")
                TestRunner.assertEqual(groupId, 7, "Second event should preserve groupId")
            } else {
                TestRunner.assertTrue(false, "Second event should be .itemGroupUpdated")
            }
        }
    }

    @MainActor
    private static func testColorToHexString() {
        let leadingZero = NSColor(srgbRed: 0, green: 15.0 / 255.0, blue: 16.0 / 255.0, alpha: 128.0 / 255.0)
        TestRunner.assertEqual(leadingZero.toHexString(), "#000F10", "toHexString should zero-pad RGB components")
        TestRunner.assertEqual(leadingZero.toHexString(includeAlpha: true), "#000F1080", "toHexString(includeAlpha: true) should include rounded alpha byte")

        let white = NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)
        TestRunner.assertEqual(white.toHexString(), "#FFFFFF", "White color should format to #FFFFFF")
        TestRunner.assertEqual(white.toHexString(includeAlpha: true), "#FFFFFFFF", "Opaque white should format to #FFFFFFFF")

        let transparentBlack = NSColor(srgbRed: 0, green: 0, blue: 0, alpha: 0)
        TestRunner.assertEqual(transparentBlack.toHexString(), "#000000", "Black color should format to #000000")
        TestRunner.assertEqual(transparentBlack.toHexString(includeAlpha: true), "#00000000", "Transparent black should format to #00000000")
    }
}
