//
//  StorageInspectorSheet.swift
//  Clipboard
//
//  存储空间占用深度透视与用户自主选择清理弹窗（支持左侧列表 + 右侧极速高清预览与沉浸式大图灯箱）
//

import AppKit
import SwiftUI

struct StorageInspectorSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var service = StorageAnalysisService.shared

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
        selectedBytes.formatted(.byteCount(style: .file))
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
                            Text("已释放 \(lastFreedBytes.formatted(.byteCount(style: .file)))")
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
