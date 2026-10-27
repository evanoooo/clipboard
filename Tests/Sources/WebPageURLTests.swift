//
//  WebPageURLTests.swift
//  Tests
//
//  Unit tests for simple web page URL detection vs. file downloads.
//

import Foundation

extension URL {
    private static let testWebPageExtensions: Set<String> = [
        "html", "htm", "shtml", "xhtml", "php", "asp", "aspx", "jsp"
    ]

    private static let testDownloadExtensions: Set<String> = [
        "zip", "rar", "7z", "tar", "gz", "iso", "dmg", "pkg", "exe", "msi", "apk", "ipa", "pdf"
    ]

    var testIsLikelySimpleWebPage: Bool {
        guard let scheme = scheme?.lowercased(),
              scheme == "http" || scheme == "https"
        else {
            return false
        }

        let ext = pathExtension.lowercased()
        if !ext.isEmpty {
            if !Self.testWebPageExtensions.contains(ext) {
                return false
            }
        }

        if let query = query?.lowercased() {
            for downloadExt in Self.testDownloadExtensions {
                if query.contains(".\(downloadExt)") {
                    return false
                }
            }
        }

        return true
    }

    var testIsLikelyDownloadURL: Bool {
        !testIsLikelySimpleWebPage
    }
}

@MainActor
enum WebPageURLTests {
    static func run(runner: TestRunner.Type) {
        print("\n--- Testing WebPageURL / Download Detection ---")

        // 1. Simple Web Pages
        let simpleWebPages = [
            "https://apple.com",
            "https://apple.com/",
            "https://github.com/swiftlang/swift",
            "https://news.ycombinator.com/item?id=123",
            "https://example.com/index.html",
            "https://example.com/docs/page.htm",
            "https://example.com/profile.php?user=42",
            "https://example.com/default.aspx",
            "https://example.com/content.shtml",
            "https://en.wikipedia.org/wiki/Swift_(programming_language)",
            "http://localhost:8080/dashboard"
        ]

        for urlString in simpleWebPages {
            let url = URL(string: urlString)!
            runner.assertTrue(url.testIsLikelySimpleWebPage, "Should identify as simple web page: \(urlString)")
            runner.assertFalse(url.testIsLikelyDownloadURL, "Should NOT identify as download: \(urlString)")
        }

        // 2. File Download URLs (archives, installers, binaries, media, documents)
        let downloadURLs = [
            "https://example.com/release/app.dmg",
            "https://example.com/release/installer.pkg",
            "https://example.com/files/archive.zip",
            "https://example.com/files/archive.tar.gz",
            "https://example.com/files/archive.7z",
            "https://example.com/files/archive.rar",
            "https://example.com/files/system.iso",
            "https://example.com/bin/setup.exe",
            "https://example.com/bin/setup.msi",
            "https://example.com/bin/program.bin",
            "https://example.com/bin/tool.sh",
            "https://example.com/apps/app.apk",
            "https://example.com/apps/app.ipa",
            "https://example.com/docs/report.pdf",
            "https://example.com/docs/sheet.xlsx",
            "https://example.com/docs/slides.pptx",
            "https://example.com/media/video.mp4",
            "https://example.com/media/audio.mp3",
            "https://example.com/torrents/linux.torrent",
            "https://example.com/download?file=app.zip",
            "https://example.com/get.php?f=setup.dmg&version=1.0",
            "ftp://example.com/index.html" // non-http/https
        ]

        for urlString in downloadURLs {
            let url = URL(string: urlString)!
            runner.assertFalse(url.testIsLikelySimpleWebPage, "Should NOT identify as simple web page: \(urlString)")
            runner.assertTrue(url.testIsLikelyDownloadURL, "Should identify as file download: \(urlString)")
        }

        print("✓ WebPageURL / Download Detection tests passed!")
    }
}
