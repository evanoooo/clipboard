//
//  StorageInspectorSheet.swift
//  Clipboard
//
//  存储空间占用深度透视与用户自主选择清理弹窗（支持左侧列表 + 右侧极速高清预览与沉浸式大图灯箱）
//

import AppKit
import ImageIO
import SwiftUI

struct StorageInspectorSheet: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var service = StorageAnalysisService.shared

    @State private var selectedFilter: StoragePresetFilter = .all
    @State private var selectedIds: Set<Int64> = []
    @State private var previewItem: StorageItemSummary? = nil
    @State private var showDeleteConfirmation = false
    @State private var lastFreedBytes: Int64 = 0
    @State private var lightboxTarget: (image: NSImage, dimensions: CGSize?, title: String)? = nil

    private var items: [StorageItemSummary] {
        service.topItems
    }

    private var unprotectableItems: [StorageItemSummary] {
        items.filter { !$0.isProtected }
    }

    private var selectedBytes: Int64 {
        items.filter { selectedIds.contains($0.id) }.reduce(0) { $0 + $1.byteSize }
    }

    private var selectedBytesFormatted: String {
        ByteCountFormatter.string(fromByteCount: selectedBytes, countStyle: .file)
    }

    var body: some View {
        ZStack {
            VStack(spacing: 0) {
                // MARK: - 顶部导航栏
                HStack(alignment: .center) {
                    VStack(alignment: .leading, spacing: Const.space4) {
                        Text("存储空间深度透视")
                            .font(.headline)
                            .bold()
                        Text("查看占用最大的历史记录，支持点击条目直接在右侧实时预览详情，由您自主勾选清理。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.title2)
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, Const.space20)
                .padding(.top, Const.space16)
                .padding(.bottom, Const.space12)

                Divider()

                // MARK: - 预设快速筛选 Chip 栏
                HStack(spacing: Const.space8) {
                    ForEach(StoragePresetFilter.allCases) { filter in
                        Button {
                            selectedFilter = filter
                            selectedIds.removeAll()
                            Task {
                                await service.loadTopItems(limit: 100, filter: filter)
                                syncFirstPreviewItem()
                            }
                        } label: {
                            Text(filter.rawValue)
                                .font(.callout)
                                .padding(.horizontal, Const.space12)
                                .padding(.vertical, Const.space6)
                                .background(
                                    selectedFilter == filter
                                        ? Color.accentColor.opacity(0.15)
                                        : Color.secondary.opacity(0.1)
                                )
                                .foregroundStyle(
                                    selectedFilter == filter
                                        ? Color.accentColor
                                        : Color.primary
                                )
                                .clipShape(Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                    Spacer()
                }
                .padding(.horizontal, Const.space20)
                .padding(.vertical, Const.space10)

                Divider()

                // MARK: - 主体区域：左侧列表 + 右侧实时预览 (Master-Detail)
                HStack(spacing: 0) {
                    // 左侧清单列表
                    VStack(spacing: 0) {
                        if service.isAnalyzing {
                            Spacer()
                            ProgressView("正在深度扫描数据库大文件...")
                                .controlSize(.regular)
                            Spacer()
                        } else if items.isEmpty {
                            Spacer()
                            VStack(spacing: Const.space8) {
                                Image(systemName: "checkmark.seal.fill")
                                    .font(.system(size: 36))
                                    .foregroundStyle(.secondary)
                                Text("没有符合该条件的大体积条目")
                                    .font(.callout)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                        } else {
                            List(items) { item in
                                StorageItemRow(
                                    item: item,
                                    isSelected: selectedIds.contains(item.id),
                                    isCurrentPreview: previewItem?.id == item.id,
                                    onToggle: {
                                        if selectedIds.contains(item.id) {
                                            selectedIds.remove(item.id)
                                        } else {
                                            selectedIds.insert(item.id)
                                        }
                                    },
                                    onSelectForPreview: {
                                        previewItem = item
                                    }
                                )
                                .listRowInsets(EdgeInsets(top: 2, leading: 8, bottom: 2, trailing: 8))
                                .listRowSeparator(.hidden)
                            }
                            .listStyle(.plain)
                        }
                    }
                    .frame(width: 410)

                    Divider()

                    // 右侧实时预览面板
                    ZStack {
                        if let previewItem {
                            StorageItemPreviewView(
                                item: previewItem,
                                onOpenLightbox: { image, dims, title in
                                    withAnimation(.easeInOut(duration: 0.2)) {
                                        lightboxTarget = (image, dims, title)
                                    }
                                }
                            )
                        } else {
                            VStack(spacing: Const.space12) {
                                Image(systemName: "photo.on.rectangle.angled")
                                    .font(.system(size: 36))
                                    .foregroundStyle(.secondary)
                                Text("点击左侧任意条目预览内容")
                                    .font(.callout)
                                    .foregroundStyle(.secondary)
                            }
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                        }
                    }
                    .frame(minWidth: 460, maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color(nsColor: .windowBackgroundColor))
                }

                Divider()

                // MARK: - 底部操作栏
                HStack(spacing: Const.space12) {
                    Button(selectedIds.count == unprotectableItems.count && !unprotectableItems.isEmpty ? "取消全选" : "全选未保护项") {
                        if selectedIds.count == unprotectableItems.count {
                            selectedIds.removeAll()
                        } else {
                            selectedIds = Set(unprotectableItems.map(\.id))
                        }
                    }
                    .buttonStyle(.plain)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .disabled(unprotectableItems.isEmpty)

                    if lastFreedBytes > 0 {
                        HStack(spacing: Const.space6) {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                            Text("已释放 \(ByteCountFormatter.string(fromByteCount: lastFreedBytes, countStyle: .file))")
                                .font(.callout)
                                .foregroundStyle(.secondary)

                            Button("立即整理碎片") {
                                Task {
                                    _ = try? await service.vacuumDatabase()
                                    withAnimation {
                                        lastFreedBytes = 0
                                    }
                                }
                            }
                            .buttonStyle(.link)
                            .font(.callout)
                        }
                        .transition(.opacity)
                    }

                    Spacer()

                    if !selectedIds.isEmpty {
                        Text("已选 \(selectedIds.count) 项 · 预计释放 \(selectedBytesFormatted)")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }

                    Button(role: .destructive) {
                        showDeleteConfirmation = true
                    } label: {
                        Text("清理选中项")
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
                    .disabled(selectedIds.isEmpty)
                }
                .padding(.horizontal, Const.space20)
                .padding(.vertical, Const.space12)
            }
            .frame(width: 980, height: 640)

            // 全尺寸大图沉浸式灯箱
            if let target = lightboxTarget {
                StorageImageLightboxOverlay(
                    image: target.image,
                    dimensions: target.dimensions,
                    title: target.title
                ) {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        lightboxTarget = nil
                    }
                }
            }
        }
        .task {
            await service.loadTopItems(limit: 100, filter: selectedFilter)
            syncFirstPreviewItem()
        }
        .confirmationDialog(
            "确认清理选中的 \(selectedIds.count) 项记录？",
            isPresented: $showDeleteConfirmation,
            titleVisibility: .visible
        ) {
            Button("彻底清理并释放约 \(selectedBytesFormatted)", role: .destructive) {
                performCleanup()
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("清理后这些历史项将从剪贴板数据库中永久移除。带有收藏或标签的条目受机制保护不会被清理。")
        }
    }

    private func syncFirstPreviewItem() {
        if let current = previewItem, items.contains(where: { $0.id == current.id }) {
            return
        }
        previewItem = items.first
    }

    private func performCleanup() {
        let idsToDelete = Array(selectedIds)
        if let current = previewItem, idsToDelete.contains(current.id) {
            previewItem = nil
        }
        Task {
            do {
                let freed = try await service.deleteItems(ids: idsToDelete)
                withAnimation {
                    lastFreedBytes = freed
                }
                selectedIds.removeAll()
                await service.loadTopItems(limit: 100, filter: selectedFilter)
                syncFirstPreviewItem()
            } catch {
                log.error("Failed to delete storage items: \(error)")
            }
        }
    }
}

// MARK: - 单条大文件列表项

struct StorageItemRow: View {
    let item: StorageItemSummary
    let isSelected: Bool
    let isCurrentPreview: Bool
    let onToggle: () -> Void
    let onSelectForPreview: () -> Void

    var body: some View {
        HStack(spacing: Const.space10) {
            // 勾选框或锁定图标
            if item.isProtected {
                Image(systemName: "lock.shield.fill")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .frame(width: 20)
                    .help("已受保护（已加星收藏或绑定分类标签），不可删除")
            } else {
                Toggle("", isOn: Binding(
                    get: { isSelected },
                    set: { _ in onToggle() }
                ))
                .labelsHidden()
                .toggleStyle(.checkbox)
                .frame(width: 20)
            }

            // 类型小图标
            Image(systemName: item.typeIconAndColor.icon)
                .font(.body)
                .foregroundStyle(item.typeIconAndColor.color)
                .frame(width: 20)

            // 内容摘要与来源
            VStack(alignment: .leading, spacing: 2) {
                Text(item.displaySummary)
                    .font(.callout)
                    .lineLimit(1)
                    .truncationMode(.tail)

                HStack(spacing: Const.space8) {
                    if let app = item.appName, !app.isEmpty {
                        Text("来自 \(app)")
                    }
                    Text(item.formattedDate)

                    if item.group != -1 {
                        let chipName = CategoryChipStore.shared.chips.first(where: { $0.id == item.group })?.name ?? "已收藏"
                        Label(chipName, systemImage: "star.fill")
                            .foregroundStyle(.orange)
                    }
                    if let tag = item.tag, !tag.isEmpty, !StorageItemSummary.standardTypeTags.contains(tag.lowercased()) {
                        Label(tag, systemImage: "tag.fill")
                            .foregroundStyle(.blue)
                    }
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
            }

            Spacer()

            // 体积标注
            Text(item.formattedSize)
                .font(.system(.callout, design: .monospaced))
                .bold()
                .foregroundStyle(.primary)
        }
        .padding(.horizontal, Const.space8)
        .padding(.vertical, Const.space6)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isCurrentPreview ? Color.accentColor.opacity(0.12) : Color.clear)
        )
        .contentShape(Rectangle())
        .onTapGesture {
            onSelectForPreview()
        }
    }
}

// MARK: - 右侧实时高清预览视图

struct StorageItemPreviewView: View {
    let item: StorageItemSummary
    var onOpenLightbox: ((NSImage, CGSize?, String) -> Void)? = nil

    @State private var isLoading: Bool = false
    @State private var nsImage: NSImage? = nil
    @State private var textContent: String? = nil
    @State private var totalCharCount: Int? = nil
    @State private var isTruncated: Bool = false
    @State private var imageDimensions: CGSize? = nil
    @State private var isCopied: Bool = false
    @State private var isActualSize: Bool = false

    private struct PreviewResult: @unchecked Sendable {
        let image: NSImage?
        let imageDimensions: CGSize?
        let textContent: String?
        let totalCharCount: Int?
        let isTruncated: Bool
    }

    var body: some View {
        VStack(spacing: Const.space10) {
            // MARK: - 主视口容器（占满全部主要空间）
            ZStack(alignment: .topTrailing) {
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color(nsColor: .controlBackgroundColor))

                if isLoading {
                    ProgressView("正在读取大项数据...")
                        .controlSize(.small)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let nsImage {
                    Group {
                        if isActualSize {
                            ScrollView([.horizontal, .vertical]) {
                                Image(nsImage: nsImage)
                                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                            }
                        } else {
                            Image(nsImage: nsImage)
                                .resizable()
                                .scaledToFit()
                                .padding(Const.space8)
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                        }
                    }
                    .contentShape(Rectangle())
                    .onTapGesture(count: 2) {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            isActualSize.toggle()
                        }
                    }

                    // 右上角半透明悬浮控制栏
                    HStack(spacing: Const.space6) {
                        Button {
                            withAnimation(.easeInOut(duration: 0.2)) {
                                isActualSize.toggle()
                            }
                        } label: {
                            Image(systemName: isActualSize ? "arrow.down.right.and.arrow.up.left" : "1.magnifyingglass")
                                .font(.system(size: 11, weight: .bold))
                                .foregroundStyle(.primary)
                                .frame(width: 28, height: 28)
                                .background(.ultraThinMaterial)
                                .clipShape(Circle())
                                .shadow(color: .black.opacity(0.12), radius: 2, y: 1)
                        }
                        .buttonStyle(.plain)
                        .help(isActualSize ? "自适应窗口 (双击图片也可切换)" : "1:1 实际原始像素 (双击图片也可切换)")

                        Button {
                            onOpenLightbox?(nsImage, imageDimensions, item.displaySummary)
                        } label: {
                            Image(systemName: "arrow.up.left.and.arrow.down.right")
                                .font(.system(size: 11, weight: .bold))
                                .foregroundStyle(.primary)
                                .frame(width: 28, height: 28)
                                .background(.ultraThinMaterial)
                                .clipShape(Circle())
                                .shadow(color: .black.opacity(0.12), radius: 2, y: 1)
                        }
                        .buttonStyle(.plain)
                        .help("全屏放大查看细节 (ESC 退出)")
                    }
                    .padding(Const.space10)
                } else if let textContent {
                    VStack(alignment: .leading, spacing: 0) {
                        ScrollView {
                            Text(textContent)
                                .font(.system(.caption, design: .monospaced))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(Const.space12)
                        }
                        if isTruncated, let count = totalCharCount {
                            let formattedCount = NumberFormatter.localizedString(from: NSNumber(value: count), number: .decimal)
                            HStack(spacing: Const.space6) {
                                Image(systemName: "info.circle.fill")
                                    .foregroundStyle(.blue)
                                Text("为保障流畅极速体验，已截断展示前 20,000 字符（全文共 \(formattedCount) 字符）")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                Spacer()
                            }
                            .padding(.horizontal, Const.space12)
                            .padding(.vertical, Const.space6)
                            .background(Color.blue.opacity(0.08))
                        }
                    }
                } else {
                    VStack(spacing: Const.space8) {
                        Image(systemName: "photo")
                            .font(.system(size: 32))
                            .foregroundStyle(.secondary)
                        Text("无可预览内容")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .frame(maxHeight: .infinity)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(Color.secondary.opacity(0.15), lineWidth: 1)
            )

            // MARK: - 现代化紧凑单行元数据底栏（节省垂直空间留给大图）
            HStack(alignment: .center, spacing: Const.space10) {
                Label(item.friendlyTypeName, systemImage: item.typeIconAndColor.icon)
                    .font(.callout)
                    .bold()
                    .foregroundStyle(item.typeIconAndColor.color)

                Text(item.formattedSize)
                    .font(.system(.callout, design: .monospaced))
                    .bold()
                    .foregroundStyle(Color.accentColor)

                Divider()
                    .frame(height: 14)

                HStack(spacing: Const.space6) {
                    if let app = item.appName, !app.isEmpty {
                        Text(app)
                    }
                    Text("·")
                    Text(item.formattedDate)

                    if let dims = imageDimensions {
                        Text("·")
                        Text("\(Int(dims.width)) × \(Int(dims.height))")
                    } else if let total = totalCharCount {
                        Text("·")
                        let formattedCount = NumberFormatter.localizedString(from: NSNumber(value: total), number: .decimal)
                        Text("\(formattedCount) 字符")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)

                Spacer()

                if let img = nsImage {
                    Button {
                        onOpenLightbox?(img, imageDimensions, item.displaySummary)
                    } label: {
                        Label("放大", systemImage: "arrow.up.left.and.arrow.down.right")
                            .font(.caption)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }

                Button {
                    copyToClipboard()
                } label: {
                    Label(isCopied ? "已复制" : "复制", systemImage: isCopied ? "checkmark" : "doc.on.doc")
                        .font(.caption)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
            .padding(.horizontal, Const.space12)
            .padding(.vertical, Const.space8)
            .background(Color.secondary.opacity(0.06))
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
        .padding(Const.space12)
        .task(id: item.id) {
            isActualSize = false
            await loadContent()
        }
    }

    private func copyToClipboard() {
        Task {
            let data = await Task.detached(priority: .userInitiated) {
                PasteDataPointReader.loadData(id: item.id, uniqueId: item.uniqueId)
            }.value
            guard let data else { return }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setData(data, forType: NSPasteboard.PasteboardType(item.type))
            isCopied = true
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            isCopied = false
        }
    }

    private func loadContent() async {
        isLoading = true
        defer { isLoading = false }
        nsImage = nil
        textContent = nil
        totalCharCount = nil
        isTruncated = false
        imageDimensions = nil

        let currentId = item.id
        let uniqueId = item.uniqueId
        let itemType = item.type

        let result = await Task.detached(priority: .userInitiated) { () -> PreviewResult? in
            guard let data = PasteDataPointReader.loadData(id: currentId, uniqueId: uniqueId) else {
                return nil
            }

            let lower = itemType.lowercased()
            if lower.contains("png") || lower.contains("tiff") || lower.contains("jpeg") || lower.contains("image") {
                if let source = CGImageSourceCreateWithData(data as CFData, nil) {
                    var dims: CGSize? = nil
                    if let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] {
                        if let w = properties[kCGImagePropertyPixelWidth] as? CGFloat,
                           let h = properties[kCGImagePropertyPixelHeight] as? CGFloat {
                            dims = CGSize(width: w, height: h)
                        }
                    }
                    let maxDimension: CGFloat = 2048
                    let thumbnailOptions: [CFString: Any] = [
                        kCGImageSourceCreateThumbnailFromImageAlways: true,
                        kCGImageSourceShouldCacheImmediately: true,
                        kCGImageSourceCreateThumbnailWithTransform: true,
                        kCGImageSourceThumbnailMaxPixelSize: maxDimension
                    ]
                    if let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbnailOptions as CFDictionary) {
                        let img = NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
                        return PreviewResult(image: img, imageDimensions: dims ?? img.size, textContent: nil, totalCharCount: nil, isTruncated: false)
                    }
                }
                if let img = NSImage(data: data) {
                    let dims = img.representations.first.map { CGSize(width: $0.pixelsWide, height: $0.pixelsHigh) } ?? img.size
                    return PreviewResult(image: img, imageDimensions: dims, textContent: nil, totalCharCount: nil, isTruncated: false)
                }
                return nil
            } else if lower.contains("rtf") {
                let text: String?
                if let attr = try? NSAttributedString(data: data, options: [.documentType: NSAttributedString.DocumentType.rtf], documentAttributes: nil) {
                    text = attr.string
                } else {
                    text = String(data: data, encoding: .utf8)
                }
                guard let fullText = text else { return nil }
                let total = fullText.count
                let maxChars = 20_000
                let truncated = total > maxChars
                let preview = truncated ? String(fullText.prefix(maxChars)) : fullText
                return PreviewResult(image: nil, imageDimensions: nil, textContent: preview, totalCharCount: total, isTruncated: truncated)
            } else {
                guard let fullText = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .ascii) else {
                    return nil
                }
                let total = fullText.count
                let maxChars = 20_000
                let truncated = total > maxChars
                let preview = truncated ? String(fullText.prefix(maxChars)) : fullText
                return PreviewResult(image: nil, imageDimensions: nil, textContent: preview, totalCharCount: total, isTruncated: truncated)
            }
        }.value

        if Task.isCancelled { return }

        if let result {
            nsImage = result.image
            imageDimensions = result.imageDimensions
            textContent = result.textContent
            totalCharCount = result.totalCharCount
            isTruncated = result.isTruncated
        }
    }
}

// MARK: - 全尺寸大图沉浸式灯箱 (Lightbox)

struct StorageImageLightboxOverlay: View {
    let image: NSImage
    let dimensions: CGSize?
    let title: String
    let onClose: () -> Void

    @State private var scale: CGFloat = 1.0
    @State private var lastScale: CGFloat = 1.0
    @State private var offset: CGSize = .zero
    @State private var lastOffset: CGSize = .zero

    var body: some View {
        ZStack {
            // 背景暗色材质遮罩
            Color.black.opacity(0.85)
                .ignoresSafeArea()
                .onTapGesture {
                    onClose()
                }

            // 大图展示区，支持缩放和平移
            GeometryReader { proxy in
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
                    .scaleEffect(scale)
                    .offset(offset)
                    .frame(width: proxy.size.width, height: proxy.size.height)
                    .gesture(
                        MagnificationGesture()
                            .onChanged { val in
                                scale = lastScale * val
                            }
                            .onEnded { _ in
                                lastScale = max(0.5, min(scale, 4.0))
                                scale = lastScale
                            }
                            .simultaneously(with:
                                DragGesture()
                                    .onChanged { val in
                                        offset = CGSize(
                                            width: lastOffset.width + val.translation.width,
                                            height: lastOffset.height + val.translation.height
                                        )
                                    }
                                    .onEnded { _ in
                                        lastOffset = offset
                                    }
                            )
                    )
                    .onTapGesture(count: 2) {
                        withAnimation(.spring()) {
                            if scale > 1.2 {
                                scale = 1.0
                                lastScale = 1.0
                                offset = .zero
                                lastOffset = .zero
                            } else {
                                scale = 2.0
                                lastScale = 2.0
                            }
                        }
                    }
            }

            // 顶部浮动标题与控制栏
            VStack {
                HStack(spacing: Const.space12) {
                    Text(title)
                        .font(.headline)
                        .foregroundStyle(.white)

                    if let dimensions {
                        Text("\(Int(dimensions.width)) × \(Int(dimensions.height)) 像素")
                            .font(.caption)
                            .foregroundStyle(.white.opacity(0.7))
                    }

                    Spacer()

                    Button {
                        withAnimation(.spring()) {
                            scale = 1.0
                            lastScale = 1.0
                            offset = .zero
                            lastOffset = .zero
                        }
                    } label: {
                        Text("100% 还原")
                            .font(.caption)
                            .foregroundStyle(.white)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 4)
                            .background(Color.white.opacity(0.2))
                            .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)

                    Button {
                        withAnimation(.spring()) {
                            scale = min(scale * 1.3, 4.0)
                            lastScale = scale
                        }
                    } label: {
                        Image(systemName: "plus.magnifyingglass")
                            .foregroundStyle(.white)
                            .padding(6)
                            .background(Color.white.opacity(0.2))
                            .clipShape(Circle())
                    }
                    .buttonStyle(.plain)

                    Button {
                        withAnimation(.spring()) {
                            scale = max(scale / 1.3, 0.5)
                            lastScale = scale
                        }
                    } label: {
                        Image(systemName: "minus.magnifyingglass")
                            .foregroundStyle(.white)
                            .padding(6)
                            .background(Color.white.opacity(0.2))
                            .clipShape(Circle())
                    }
                    .buttonStyle(.plain)

                    Button {
                        onClose()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.title2)
                            .foregroundStyle(.white.opacity(0.85))
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, Const.space20)
                .padding(.vertical, Const.space14)
                .background(Color.black.opacity(0.5))

                Spacer()

                Text("双击快速放大/还原 · 支持拖动与手势缩放 · 点击背景或按右上角 ✕ 退出")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.6))
                    .padding(.bottom, Const.space12)
            }
        }
        .transition(.opacity)
    }
}
