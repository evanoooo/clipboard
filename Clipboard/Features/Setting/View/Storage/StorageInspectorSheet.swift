//
//  StorageInspectorSheet.swift
//  Clipboard
//
//  存储空间占用深度透视与用户自主选择清理弹窗（支持左侧列表 + 右侧实时高清预览）
//

import AppKit
import SwiftUI

struct StorageInspectorSheet: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var service = StorageAnalysisService.shared

    @State private var selectedFilter: StoragePresetFilter = .all
    @State private var selectedIds: Set<Int64> = []
    @State private var previewItem: StorageItemSummary? = nil
    @State private var showDeleteConfirmation = false
    @State private var showVacuumSuggestion = false
    @State private var lastFreedBytes: Int64 = 0

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
                .frame(width: 490)

                Divider()

                // 右侧实时预览面板
                ZStack {
                    if let previewItem {
                        StorageItemPreviewView(item: previewItem)
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
                .frame(minWidth: 350, maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(nsColor: .windowBackgroundColor))
            }

            Divider()

            // MARK: - 底部操作栏
            HStack {
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
        .frame(width: 860, height: 560)
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
        .alert("清理完成", isPresented: $showVacuumSuggestion) {
            Button("立即压缩数据库") {
                Task {
                    _ = try? await service.vacuumDatabase()
                }
            }
            Button("稍后手动压缩", role: .cancel) {}
        } message: {
            let freedStr = ByteCountFormatter.string(fromByteCount: lastFreedBytes, countStyle: .file)
            Text("已成功清理记录，共释放 \(freedStr) 数据。建议立即压缩数据库将碎片空间物理归还给 macOS。")
        }
    }

    private func syncFirstPreviewItem() {
        if previewItem == nil || !items.contains(where: { $0.id == previewItem?.id }) {
            previewItem = items.first
        }
    }

    private func performCleanup() {
        let idsToDelete = Array(selectedIds)
        Task {
            do {
                let freed = try await service.deleteItems(ids: idsToDelete)
                lastFreedBytes = freed
                selectedIds.removeAll()
                await service.loadTopItems(limit: 100, filter: selectedFilter)
                syncFirstPreviewItem()
                showVacuumSuggestion = true
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

    @State private var isLoading: Bool = false
    @State private var nsImage: NSImage? = nil
    @State private var textContent: String? = nil
    @State private var imageDimensions: CGSize? = nil
    @State private var isCopied: Bool = false

    var body: some View {
        VStack(spacing: Const.space12) {
            // 视口容器
            ZStack {
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color(nsColor: .controlBackgroundColor))

                if isLoading {
                    ProgressView("正在读取大项数据...")
                        .controlSize(.small)
                } else if let nsImage {
                    Image(nsImage: nsImage)
                        .resizable()
                        .scaledToFit()
                        .padding(Const.space8)
                } else if let textContent {
                    ScrollView {
                        Text(textContent)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(Const.space12)
                    }
                } else {
                    VStack(spacing: Const.space8) {
                        Image(systemName: "photo")
                            .font(.system(size: 32))
                            .foregroundStyle(.secondary)
                        Text("无可用可视预览")
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

            // 详细元数据面板
            VStack(alignment: .leading, spacing: Const.space8) {
                HStack(alignment: .center) {
                    Label(item.friendlyTypeName, systemImage: item.typeIconAndColor.icon)
                        .font(.callout)
                        .bold()
                        .foregroundStyle(item.typeIconAndColor.color)

                    Spacer()

                    Text(item.formattedSize)
                        .font(.system(.callout, design: .monospaced))
                        .bold()
                        .foregroundStyle(Color.accentColor)
                }

                Divider()

                StorageMetadataRow(label: "来源应用", value: item.appName ?? "未知应用")
                StorageMetadataRow(label: "复制时间", value: item.formattedDate)

                if let dims = imageDimensions {
                    StorageMetadataRow(label: "图片分辨率", value: "\(Int(dims.width)) × \(Int(dims.height)) 像素")
                } else if let text = textContent {
                    StorageMetadataRow(label: "字符总数", value: "\(text.count) 个字符")
                }

                HStack {
                    Spacer()
                    Button {
                        copyToClipboard()
                    } label: {
                        Label(isCopied ? "已复制到剪贴板" : "复制此项内容", systemImage: isCopied ? "checkmark" : "doc.on.doc")
                            .font(.caption)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
                .padding(.top, Const.space4)
            }
            .padding(Const.space12)
            .background(Color.secondary.opacity(0.06))
            .clipShape(RoundedRectangle(cornerRadius: 10))
        }
        .padding(Const.space16)
        .task(id: item.id) {
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
        imageDimensions = nil

        let data = await Task.detached(priority: .userInitiated) {
            PasteDataPointReader.loadData(id: item.id, uniqueId: item.uniqueId)
        }.value

        guard let data else { return }

        let lower = item.type.lowercased()
        if lower.contains("png") || lower.contains("tiff") || lower.contains("jpeg") || lower.contains("image") {
            if let img = NSImage(data: data) {
                nsImage = img
                if let rep = img.representations.first {
                    imageDimensions = CGSize(width: rep.pixelsWide, height: rep.pixelsHigh)
                } else {
                    imageDimensions = img.size
                }
            }
        } else if lower.contains("rtf") {
            if let attr = try? NSAttributedString(data: data, options: [.documentType: NSAttributedString.DocumentType.rtf], documentAttributes: nil) {
                textContent = attr.string
            } else {
                textContent = String(data: data, encoding: .utf8)
            }
        } else {
            textContent = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .ascii)
        }
    }
}

// MARK: - 元数据排版辅助行

struct StorageMetadataRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 68, alignment: .leading)
            Text(value)
                .font(.caption)
                .foregroundStyle(.primary)
                .lineLimit(2)
            Spacer()
        }
    }
}
