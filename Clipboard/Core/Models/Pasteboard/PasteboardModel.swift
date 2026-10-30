//
//  PasteboardModel.swift
//  Clipboard
//
//  Created by crown on 2025/9/13.
//

import AppKit
import ImageIO
import UniformTypeIdentifiers

final class PasteboardModel: Identifiable, Codable {
    var id: Int64?
    /// 仅内存态缓存数据库的 sort_order，用于撤销删除后回到原位；不参与 Codable。
    var sortOrder: Int64 = 0
    let uniqueId: String
    let pasteboardType: PasteboardType
    private var _data: Data?

    var hasLoadedData: Bool {
        _data != nil
    }

    var data: Data {
        get {
            if let _data {
                return _data
            }
            if let loaded = PasteDataPointReader.loadData(id: id, uniqueId: uniqueId) {
                _data = loaded
                if runtimeCache.codeDetectionState == .none, length > 300 {
                    runtimeCache.codeDetectionState = .uncomputed
                }
                return loaded
            }
            return Data()
        }
        set {
            _data = newValue
        }
    }
    let showData: Data?
    private(set) var timestamp: Int64
    var appID: Int64?
    let sourceBundleID: String?
    private let sourcePath: String
    private let sourceName: String
    var appPath: String { appID.flatMap { SourceAppCache.shared.apps[$0]?.path } ?? sourcePath }
    var appName: String { appID.flatMap { SourceAppCache.shared.apps[$0]?.name } ?? sourceName }
    private(set) var searchText: String
    let length: Int
    private var _attributeString: NSAttributedString?
    /// 截取后的富文本预览（支持闲置释放）
    var attributeString: NSAttributedString {
        if let cached = _attributeString { return cached }
        let generated = NSAttributedString(with: showData, type: pasteboardType) ?? NSAttributedString()
        _attributeString = generated
        return generated
    }

    private var _writeItem: PasteboardWritingItem?
    var writeItem: PasteboardWritingItem {
        if let cached = _writeItem { return cached }
        let item = PasteboardWritingItem(
            type: pasteboardType,
            plainText: pasteboardType.isText() ? plainText : "",
            appName: appName,
            timestamp: timestamp,
            model: self
        )
        _writeItem = item
        return item
    }
    private(set) lazy var type = PasteModelType(
        with: pasteboardType,
        model: self
    )

    private(set) var group: Int
    let tag: String
    /// 用户别名（原文），空串表示未设置；不影响 `tag` 的类型语义。
    private(set) var alias: String
    private(set) var hidden: Bool
    var runtimeCache = PasteboardModelRuntimeCache()

    var hasBgColor: Bool {
        cachedHasBackgroundColor
    }

    /// 轻量文本预览：纯文本直接从 showData 读取 UTF-8 字符串，杜绝无谓构建重量级 NSAttributedString
    var previewPlainText: String {
        if let cached = runtimeCache.plainText { return cached }
        if pasteboardType == .string, let showData, let str = String(data: showData, encoding: .utf8) {
            return str
        }
        return attributeString.string
    }

    /// 是否为纯链接文本；优先基于轻量字符串计算并缓存，避免每次调用重复扫描或提前实例化富文本
    var isLink: Bool {
        if let cached = runtimeCache.isLink { return cached }
        let result = previewPlainText.isLink()
        runtimeCache.isLink = result
        return result
    }

    /// 是否为 CSS 十六进制颜色值；优先基于轻量字符串计算并缓存
    var isCSS: Bool {
        if let cached = runtimeCache.isCSS { return cached }
        let result = previewPlainText.isCSSHexColor
        runtimeCache.isCSS = result
        return result
    }

    init(
        pasteboardType: PasteboardType,
        data: Data? = nil,
        showData: Data?,
        timestamp: Int64,
        appPath: String,
        appName: String,
        searchText: String,
        length: Int,
        group: Int,
        tag: String,
        alias: String = "",
        hidden: Bool = false,
        uniqueId: String? = nil,
        appID: Int64? = nil,
        sourceBundleID: String? = nil
    ) {
        self.pasteboardType = pasteboardType
        self._data = data
        self.showData = showData
        self.timestamp = timestamp
        self.sourcePath = appPath
        self.sourceName = appName
        self.appID = appID
        self.sourceBundleID = sourceBundleID
        self.searchText = searchText
        self.length = length
        self.group = group
        self.tag = tag
        self.alias = alias
        self.hidden = hidden

        self.uniqueId = uniqueId ?? Self.generateUniqueId(
            for: pasteboardType,
            data: data ?? Data()
        )

        if let data {
            if pasteboardType == .fileURL {
                if let urlString = String(data: data, encoding: .utf8) {
                    cachedFilePaths = urlString.components(separatedBy: "\n")
                        .filter { !$0.isEmpty }
                }
            }

            if pasteboardType == .png || pasteboardType == .tiff {
                cachedImageSize = Self.computeImageSize(from: data)
            }
        }

        let (bg, fg, hasBg) = computeColors()
        cachedBackgroundColor = bg
        cachedForegroundColor = fg
        cachedHasBackgroundColor = hasBg
        if type == .rich, hasBgColor, safeBgColor == nil {
            cachedRichForegrounds = Self.richForegrounds(in: attributeString)
        }
    }

    // MARK: - 纯文本（粘贴用）

    var plainText: String {
        if let cached = runtimeCache.plainText {
            return cached
        }
        let text: String
        if pasteboardType == .string {
            if let showData, length <= showData.count,
               let str = String(data: showData, encoding: .utf8) {
                runtimeCache.plainText = str
                return str
            }
            let att = NSAttributedString(with: data, type: pasteboardType)
            text = att?.string ?? (String(data: data, encoding: .utf8) ?? "")
        } else if pasteboardType.isText() {
            let att = NSAttributedString(with: data, type: pasteboardType)
            text = att?.string ?? (String(data: data, encoding: .utf8) ?? "")
        } else {
            text = String(data: data, encoding: .utf8) ?? ""
        }
        runtimeCache.plainText = text
        return text
    }

    // MARK: - 搜索文本格式化

    /// 入库侧归一化；查询侧必须使用同一实现，见 `SearchTextNormalizer.queryTokens`。
    nonisolated static func normalizeSearchText(_ raw: String) -> String {
        SearchTextNormalizer.normalize(raw)
    }

    // MARK: - 辅助

    func introString() -> String {
        switch type {
        case .none:
            return ""
        case .image:
            guard let imgSize = imageSize() else { return "" }
            return "\(Int(imgSize.width)) × \(Int(imgSize.height)) "
        case .color:
            return ""
        case .link:
            if PasteUserDefaults.enableLinkPreview {
                return attributeString.string
            }
            return String(localized: .textCount(length))
        case .string, .rich:
            return String(localized: .textCount(length))
        case .file:
            guard let filePaths = cachedFilePaths else { return "" }
            return filePaths.count > 1
                ? String(localized: .fileCount(filePaths.count))
                : (filePaths.first ?? "")
        }
    }

    func fileSize() -> Int {
        cachedFilePaths?.count ?? 0
    }

    func imageSize() -> CGSize? {
        cachedImageSize
    }

    func thumbnail() -> NSImage? {
        cachedThumbnail
    }

    /// 深度闲置清理：释放内存中常驻的重量级二进制与解码位图（原始大图随时可通过 getter 自动重载）
    func clearLoadedPayload() {
        _data = nil
        _attributeString = nil
        _writeItem = nil
        cachedThumbnail = nil
        cachedLinkMetadata = nil
        thumbnailLoadTask?.cancel()
        thumbnailLoadTask = nil
        runtimeCache.plainText = nil
        runtimeCache.richForegrounds.removeAll()
        runtimeCache.previewForegrounds = nil
        runtimeCache.highlightedCode = nil
        runtimeCache.plainTextAttributedString = nil
    }

    /// 轻量入库后清理：在数据持久化落盘与 OCR 识别完成后，释放内存中常驻的原始大二进制，保留缩略图与渲染元数据供首屏即时展示
    func evictRawData() {
        _data = nil
        runtimeCache.plainText = nil
    }

    func loadThumbnail() async -> NSImage? {
        if let cachedThumbnail {
            return cachedThumbnail
        }

        if let existingTask = thumbnailLoadTask {
            return await existingTask.value
        }

        let sData = showData
        let modelId = id
        let uId = uniqueId
        let loadedData = _data

        let task = Task.detached(priority: .userInitiated) { [weak self] () -> NSImage? in
            guard !Task.isCancelled else { return nil }
            // 性能极致优化：数据读取与解码完全在后台线程，杜绝主线程 I/O 阻塞
            let sourceData: Data
            if let sData, !sData.isEmpty {
                sourceData = sData
            } else if let loadedData {
                sourceData = loadedData
            } else if let diskData = PasteDataPointReader.loadData(id: modelId, uniqueId: uId) {
                sourceData = diskData
            } else {
                return nil
            }

            guard !Task.isCancelled else { return nil }
            let image = Self.downsampledImage(from: sourceData, maxPixelSize: 600) ?? NSImage(data: sourceData)

            guard !Task.isCancelled, let self else { return image }
            await MainActor.run {
                self.cachedThumbnail = image
                self.thumbnailLoadTask = nil
            }
            return image
        }

        thumbnailLoadTask = task
        return await task.value
    }

    nonisolated private static func downsampledImage(from data: Data, maxPixelSize: CGFloat) -> NSImage? {
        guard !withUnsafeCurrentTask(body: { $0?.isCancelled ?? false }) else { return nil }
        let options = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, options) else {
            return nil
        }
        guard !withUnsafeCurrentTask(body: { $0?.isCancelled ?? false }) else { return nil }
        let downsampleOptions = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize
        ] as CFDictionary

        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, downsampleOptions) else {
            return nil
        }
        return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
    }

    // MARK: - 状态更新

    func updateGroup(val: Int) {
        group = val
    }

    func updateHidden(val: Bool) {
        hidden = val
    }

    func updateDate() {
        timestamp = Int64(Date().timeIntervalSince1970)
    }

    func updateSearchText(val: String) {
        searchText = val
    }

    func updateAlias(val: String) {
        alias = val
    }

    /// 是否已归类至用户标签
    var hasCategoryChip: Bool {
        group != -1
    }

    func getGroupChip() -> CategoryChip? {
        guard group != -1 else { return nil }
        return CategoryChipStore.shared.chips.first(where: { $0.id == group })
    }

    func displayCategoryName() -> String {
        if let chip = getGroupChip() {
            return chip.name
        }
        return type.string
    }

    // MARK: - Codable

    enum CodingKeys: String, CodingKey {
        case id, uniqueId, pasteboardType, data, showData, timestamp
        case appPath, appName, searchText, length, group, tag, alias, hidden
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(id, forKey: .id)
        try container.encode(uniqueId, forKey: .uniqueId)
        try container.encode(pasteboardType.rawValue, forKey: .pasteboardType)
        try container.encode(data, forKey: .data)
        try container.encodeIfPresent(showData, forKey: .showData)
        try container.encode(timestamp, forKey: .timestamp)
        try container.encode(appPath, forKey: .appPath)
        try container.encode(appName, forKey: .appName)
        try container.encode(searchText, forKey: .searchText)
        try container.encode(length, forKey: .length)
        try container.encode(group, forKey: .group)
        try container.encode(tag, forKey: .tag)
        try container.encodeIfPresent(alias.isEmpty ? nil : alias, forKey: .alias)
        try container.encode(hidden, forKey: .hidden)
    }

    convenience init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let pasteboardTypeRaw = try container.decode(
            String.self,
            forKey: .pasteboardType
        )

        try self.init(
            pasteboardType: PasteboardType(pasteboardTypeRaw),
            data: container.decode(Data.self, forKey: .data),
            showData: container.decodeIfPresent(Data.self, forKey: .showData),
            timestamp: container.decode(Int64.self, forKey: .timestamp),
            appPath: container.decode(String.self, forKey: .appPath),
            appName: container.decode(String.self, forKey: .appName),
            searchText: container.decode(String.self, forKey: .searchText),
            length: container.decode(Int.self, forKey: .length),
            group: container.decode(Int.self, forKey: .group),
            tag: container.decode(String.self, forKey: .tag),
            alias: container.decodeIfPresent(String.self, forKey: .alias) ?? "",
            hidden: container.decode(Bool.self, forKey: .hidden),
            uniqueId: container.decode(String.self, forKey: .uniqueId)
        )

        id = try container.decodeIfPresent(Int64.self, forKey: .id)
    }
}

// MARK: - Equatable & Hashable

extension PasteboardModel: Equatable {
    static func == (lhs: PasteboardModel, rhs: PasteboardModel) -> Bool {
        lhs.uniqueId == rhs.uniqueId
    }
}

extension PasteboardModel: Hashable {
    func hash(into hasher: inout Hasher) {
        hasher.combine(uniqueId)
    }
}

// MARK: - PasteModelType Mapping

extension PasteModelType {
    init(with type: PasteboardType, model: PasteboardModel) {
        // 极致性能：优先从已持久化的 tag 解析，0 毫秒解析、0 内存分配、不触碰任何富文本
        if let fromTag = PasteModelType(tagValue: model.tag) {
            self = fromTag
            return
        }

        switch type {
        case .rtf, .rtfd:
            if model.isCSS {
                self = .color
            } else if model.isLink {
                self = .link
            } else {
                self = .rich
            }
        case .string:
            if model.isCSS {
                self = .color
            } else if model.isLink {
                self = .link
            } else {
                self = .string
            }
        case .png, .tiff:
            self = .image
        case .fileURL:
            self = .file
        default:
            self = .none
        }
    }
}
