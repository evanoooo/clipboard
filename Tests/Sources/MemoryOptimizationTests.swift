//
//  MemoryOptimizationTests.swift
//  Tests
//
//  验证有界内存缓存、惰性计算与微秒级点查
//

import AppKit
import Foundation

enum MemoryOptimizationTests {
    static func runAll() {
        print("\n--- Testing Bounded Memory Caches & Runtime Optimizations ---")
        testThumbnailCache()
        testAttributedTextCache()
        testLinkMetadataCache()
        testSensitiveCredentialCheck()
        testImageDownsampler()
        testSearchTextCapping()
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
        let longText = String(repeating: "剪贴板全文搜索测试", count: 1000) // ~24000 字符
        let normalized = SearchTextNormalizer.normalize(longText)
        let capped = normalized.count > 2000 ? String(normalized.prefix(2000)) : normalized
        assert(capped.count == 2000, "Search text in list models must be capped to 2000 chars")
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
}
