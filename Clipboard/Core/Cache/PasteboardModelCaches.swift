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
        let cost = Self.pixelCost(for: image)
        cache.setObject(image, forKey: uniqueId as NSString, cost: max(cost, 1024))
    }

    static func pixelCost(for image: NSImage) -> Int {
        if let rep = image.representations.first, rep.pixelsWide > 0, rep.pixelsHigh > 0 {
            return rep.pixelsWide * rep.pixelsHigh * 4
        }
        return Int(image.size.width * image.size.height * 4)
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
        // 含属性字典、字体/颜色对象与布局元数据，按单字符 ~16B 估算以使 12MB 限额真实生效
        let cost = text.length * 16
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
            bytes += ModelThumbnailCache.pixelCost(for: preview)
        }
        if let icon = metadata.iconImage {
            bytes += ModelThumbnailCache.pixelCost(for: icon)
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

/// 有界 `showData` 缩略数据 LRU 缓存（上限 200 条 / 4MB），避免重复点查与长列表常驻膨胀
nonisolated final class ModelShowDataCache: @unchecked Sendable {
    static let shared = ModelShowDataCache()
    private let cache = NSCache<NSNumber, NSData>()

    private init() {
        cache.countLimit = 200
        cache.totalCostLimit = 4 * 1024 * 1024
    }

    func data(for id: Int64) -> Data? {
        cache.object(forKey: NSNumber(value: id)) as Data?
    }

    func setData(_ data: Data, for id: Int64) {
        cache.setObject(data as NSData, forKey: NSNumber(value: id), cost: max(data.count, 256))
    }

    func remove(for id: Int64) {
        cache.removeObject(forKey: NSNumber(value: id))
    }

    func removeAll() {
        cache.removeAllObjects()
    }
}
