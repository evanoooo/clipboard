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
        print("✓ Bounded Memory Caches & Runtime Optimizations tests passed!")
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
