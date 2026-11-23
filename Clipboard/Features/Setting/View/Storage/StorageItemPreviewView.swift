//
//  StorageItemPreviewView.swift
//  Clipboard
//
//  存储空间透视器右侧实时高清预览视图
//

import AppKit
import ImageIO
import SwiftUI

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
                            let formattedCount = count.formatted(.number)
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
                        let formattedCount = total.formatted(.number)
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

        let worker = Task.detached(priority: .userInitiated) { () -> PreviewResult? in
            guard !Task.isCancelled else { return nil }

            let lower = itemType.lowercased()
            if lower.contains("png") || lower.contains("tiff") || lower.contains("jpeg") || lower.contains("image") {
                if let mediaURL = PasteDataPointReader.loadMediaURL(id: currentId, uniqueId: uniqueId) {
                    var dims: CGSize?
                    let propsOptions = [kCGImageSourceShouldCache: false] as CFDictionary
                    if let source = CGImageSourceCreateWithURL(mediaURL as CFURL, propsOptions),
                       let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                       let w = properties[kCGImagePropertyPixelWidth] as? CGFloat,
                       let h = properties[kCGImagePropertyPixelHeight] as? CGFloat {
                        dims = CGSize(width: w, height: h)
                    }
                    if let img = ImageDownsampler.downsampleNSImage(from: mediaURL, maxPixelSize: 2048) {
                        return PreviewResult(
                            image: img,
                            imageDimensions: dims ?? img.size,
                            textContent: nil,
                            totalCharCount: nil,
                            isTruncated: false
                        )
                    }
                }

                guard !Task.isCancelled,
                      let data = PasteDataPointReader.loadData(id: currentId, uniqueId: uniqueId),
                      !Task.isCancelled else {
                    return nil
                }

                var dims: CGSize?
                if let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
                   let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                   let w = properties[kCGImagePropertyPixelWidth] as? CGFloat,
                   let h = properties[kCGImagePropertyPixelHeight] as? CGFloat {
                    dims = CGSize(width: w, height: h)
                }
                if let img = ImageDownsampler.downsampleNSImage(from: data, maxPixelSize: 2048) {
                    return PreviewResult(
                        image: img,
                        imageDimensions: dims ?? img.size,
                        textContent: nil,
                        totalCharCount: nil,
                        isTruncated: false
                    )
                }
                return nil
            }

            guard let data = PasteDataPointReader.loadData(id: currentId, uniqueId: uniqueId),
                  !Task.isCancelled else {
                return nil
            }

            if lower.contains("rtf") {
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
                let maxDecodeBytes = 80_000
                let maxChars = 20_000
                if data.count > maxDecodeBytes {
                    let slice = data.prefix(maxDecodeBytes)
                    let decoded = String(decoding: slice, as: UTF8.self)
                    let preview = String(decoded.prefix(maxChars))
                    return PreviewResult(image: nil, imageDimensions: nil, textContent: preview, totalCharCount: nil, isTruncated: true)
                }
                guard let fullText = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .ascii) else {
                    return nil
                }
                let total = fullText.count
                let truncated = total > maxChars
                let preview = truncated ? String(fullText.prefix(maxChars)) : fullText
                return PreviewResult(image: nil, imageDimensions: nil, textContent: preview, totalCharCount: total, isTruncated: truncated)
            }
        }

        let result = await withTaskCancellationHandler {
            await worker.value
        } onCancel: {
            worker.cancel()
        }

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
