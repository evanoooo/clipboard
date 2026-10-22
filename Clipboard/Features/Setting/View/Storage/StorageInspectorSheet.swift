//
//  StorageInspectorSheet.swift
//  Clipboard
//
//  存储空间占用深度透视与用户自主选择清理弹窗
//

import SwiftUI

struct StorageInspectorSheet: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var service = StorageAnalysisService.shared

    @State private var selectedFilter: StoragePresetFilter = .all
    @State private var selectedIds: Set<Int64> = []
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
                    Text("查看占用最大的历史记录，由您自主勾选清理。已加星收藏与标签分类项受保护。")
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
            .padding(.vertical, Const.space16)

            Divider()

            // MARK: - 预设建议筛选条
            HStack(spacing: Const.space8) {
                ForEach(StoragePresetFilter.allCases) { filter in
                    Button {
                        selectedFilter = filter
                        selectedIds.removeAll()
                        Task {
                            await service.loadTopItems(limit: 100, filter: filter)
                        }
                    } label: {
                        Text(filter.rawValue)
                            .font(.subheadline)
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
            .padding(.vertical, Const.space12)

            Divider()

            // MARK: - 大文件清单
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
                    HStack(spacing: Const.space12) {
                        // 勾选框或锁定图标
                        if item.isProtected {
                            Image(systemName: "lock.shield.fill")
                                .font(.body)
                                .foregroundStyle(.secondary)
                                .help("已受保护（已加星收藏或绑定分类标签），不可删除")
                        } else {
                            Toggle("", isOn: Binding(
                                get: { selectedIds.contains(item.id) },
                                set: { isChecked in
                                    if isChecked {
                                        selectedIds.insert(item.id)
                                    } else {
                                        selectedIds.remove(item.id)
                                    }
                                }
                            ))
                            .labelsHidden()
                            .toggleStyle(.checkbox)
                        }

                        // 类型图标
                        Image(systemName: item.typeIconAndColor.icon)
                            .font(.body)
                            .foregroundStyle(item.typeIconAndColor.color)
                            .frame(width: 20)

                        // 内容摘要与来源
                        VStack(alignment: .leading, spacing: Const.space2) {
                            Text(item.summary.isEmpty ? "[\(item.type.capitalized)]" : item.summary)
                                .font(.callout)
                                .lineLimit(1)
                                .truncationMode(.tail)

                            HStack(spacing: Const.space8) {
                                if let app = item.appName, !app.isEmpty {
                                    Text("来自 \(app)")
                                }
                                Text(item.formattedDate)

                                if item.group != -1 {
                                    Label("已收藏", systemImage: "star.fill")
                                        .foregroundStyle(.orange)
                                }
                                if let tag = item.tag, !tag.isEmpty {
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
                    .padding(.vertical, Const.space4)
                }
                .listStyle(.plain)
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
        .frame(width: 640, height: 500)
        .task {
            await service.loadTopItems(limit: 100, filter: selectedFilter)
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

    private func performCleanup() {
        let idsToDelete = Array(selectedIds)
        Task {
            do {
                let freed = try await service.deleteItems(ids: idsToDelete)
                lastFreedBytes = freed
                selectedIds.removeAll()
                await service.loadTopItems(limit: 100, filter: selectedFilter)
                showVacuumSuggestion = true
            } catch {
                log.error("Failed to delete storage items: \(error)")
            }
        }
    }
}
