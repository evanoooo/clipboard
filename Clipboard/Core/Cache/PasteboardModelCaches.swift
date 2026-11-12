//
//  PasteboardModelCaches.swift
//  Clipboard
//
//  有界全局渲染产物缓存（NSCache），严格控制缩略图、富文本和链接预览的内存上限
//

import AppKit

final class ModelThumbnailCache: @unchecked Sendable {
    static let shared = ModelThumbnailCache()
    private let cache = NSCache<NSString, NSImage>()

    private init() {
        cache.countLimit = 120
        cache.totalCostLimit = 24 * 1024 * 1024 // 24 MB
    }

    func thumbnail(for uniqueId: String) -> NSImage? {
        cache.object(forKey: uniqueId as NSString)
    }

    func setThumbnail(_ image: NSImage, for uniqueId: String) {
        let cost = Int(image.size.width * image.size.height * 4)
        cache.setObject(image, forKey: uniqueId as NSString, cost: max(cost, 1024))
    }

    func remove(for uniqueId: String) {
        cache.removeObject(forKey: uniqueId as NSString)
    }

    func removeAll() {
        cache.removeAllObjects()
    }
}

final class ModelAttributedTextCache: @unchecked Sendable {
    static let shared = ModelAttributedTextCache()
    private let cache = NSCache<NSString, NSAttributedString>()

    private init() {
        cache.countLimit = 120
        cache.totalCostLimit = 12 * 1024 * 1024 // 12 MB
    }

    func text(for key: String) -> NSAttributedString? {
        cache.object(forKey: key as NSString)
    }

    func setText(_ text: NSAttributedString, for key: String) {
        let cost = text.length * 2
        cache.setObject(text, forKey: key as NSString, cost: max(cost, 512))
    }

    func remove(for key: String) {
        cache.removeObject(forKey: key as NSString)
    }

    func removeAll() {
        cache.removeAllObjects()
    }
}

final class LinkMetadataWrapper: NSObject {
    let metadata: LinkPreviewMetadata

    init(metadata: LinkPreviewMetadata) {
        self.metadata = metadata
    }

    var cost: Int {
        var bytes = 512
        if let preview = metadata.previewImage {
            bytes += Int(preview.size.width * preview.size.height * 4)
        }
        if let icon = metadata.iconImage {
            bytes += Int(icon.size.width * icon.size.height * 4)
        }
        return bytes
    }
}

final class ModelLinkMetadataCache: @unchecked Sendable {
    static let shared = ModelLinkMetadataCache()
    private let cache = NSCache<NSString, LinkMetadataWrapper>()

    private init() {
        cache.countLimit = 60
        cache.totalCostLimit = 16 * 1024 * 1024 // 16 MB
    }

    func metadata(for uniqueId: String) -> LinkPreviewMetadata? {
        cache.object(forKey: uniqueId as NSString)?.metadata
    }

    func setMetadata(_ meta: LinkPreviewMetadata, for uniqueId: String) {
        let wrapper = LinkMetadataWrapper(metadata: meta)
        cache.setObject(wrapper, forKey: uniqueId as NSString, cost: wrapper.cost)
    }

    func remove(for uniqueId: String) {
        cache.removeObject(forKey: uniqueId as NSString)
    }

    func removeAll() {
        cache.removeAllObjects()
    }
}
