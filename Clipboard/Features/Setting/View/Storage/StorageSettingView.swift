//
//  StorageSettingView.swift
//  Clipboard
//
//  Created by crown on 2026/1/9.
//

import SwiftUI
import UniformTypeIdentifiers

// MARK: - 存储设置视图

struct StorageSettingView: View {
    @Environment(\.colorScheme) private var colorScheme
    @StateObject private var storageService = StorageAnalysisService.shared

    @State private var totalCount: Int = 0
    @State private var isExporting = false
    @State private var isImporting = false
    @State private var isVacuuming = false
    @State private var showInspector = false
    @State private var showAlert = false
    @State private var alertTitle = ""
    @State private var alertMessage = ""

    private let db = PasteDataStore.main

    var body: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: Const.space16) {
                // MARK: - 存储健康度看板
                VStack(alignment: .leading, spacing: Const.space12) {
                    DataStatRow(
                        title: "物理磁盘总占用",
                        value: storageService.diskUsage?.formattedTotalDisk ?? "计算中..."
                    )
                    Divider()
                    DataStatRow(
                        title: "可压缩碎片空洞",
                        value: storageService.diskUsage?.formattedReclaimable ?? "0 B"
                    )
                    Divider()
                    DataStatRow(
                        title: String(localized: .storageItemCount),
                        value: String.localizedStringWithFormat(
                            String(
                                localized: "storageItemCountValue",
                                defaultValue: "%lld items",
                                table: "Localizable"
                            ),
                            totalCount
                        )
                    )

                    if !storageService.typeProportions.isEmpty {
                        Divider()
                        StorageBreakdownBarView(proportions: storageService.typeProportions)
                    }
                }
                .padding(.horizontal, Const.space16)
                .padding(.vertical, Const.space4)
                .settingsStyle()

                // MARK: - 空间透视与自主整理
                VStack(alignment: .leading, spacing: 0) {
                    DataActionRow(
                        title: "分析空间占用...",
                        subtitle: "按体积大小查看 Top 大项，由您自主勾选清理大图、富文本等旧历史",
                        buttonTitle: "深度分析",
                        isLoading: false
                    ) {
                        showInspector = true
                    }

                    Divider()

                    DataActionRow(
                        title: "压缩数据库 (Vacuum)",
                        subtitle: "整理数据库碎片，将已删除的碎片空洞物理归还给 macOS 系统",
                        buttonTitle: "立即压缩",
                        isLoading: isVacuuming
                    ) {
                        vacuumDatabase()
                    }
                }
                .padding(.horizontal, Const.space16)
                .settingsStyle()

                // MARK: - 备份与还原
                Text(.storageBackupTitle)
                    .font(.headline)
                    .bold()

                VStack(alignment: .leading, spacing: 0) {
                    DataActionRow(
                        title: String(localized: .storageExportTitle),
                        subtitle: String(localized: .storageExportDesc),
                        buttonTitle: String(localized: .storageExportButton),
                        isLoading: isExporting
                    ) {
                        exportDatabase()
                    }

                    Divider()

                    DataActionRow(
                        title: String(localized: .storageImportTitle),
                        subtitle: String(localized: .storageImportDesc),
                        buttonTitle: String(localized: .storageImportButton),
                        isLoading: isImporting
                    ) {
                        importDatabase()
                    }
                }
                .padding(.horizontal, Const.space16)
                .settingsStyle()

                Text(.storageNotesTitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                VStack(alignment: .leading, spacing: Const.space4) {
                    Text(.storageNoteDeduplicate)
                    Text(.storageNotePreserveExistingData)
                    Text(.storageNoteBackupRegularly)
                }
                .font(.caption2)
                .foregroundStyle(.secondary)

                Spacer(minLength: 20)
            }
            .padding([.horizontal, .bottom], Const.space24)
        }
        .scrollIndicators(.hidden)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task {
            totalCount = await PasteSQLManager.manager.getTotalCount()
            await storageService.refreshDiskUsage()
        }
        .sheet(isPresented: $showInspector) {
            StorageInspectorSheet()
        }
        .alert(alertTitle, isPresented: $showAlert) {
            Button(.commonConfirm, role: .cancel) {}
        } message: {
            Text(alertMessage)
        }
    }

    // MARK: - 压缩数据库

    private func vacuumDatabase() {
        isVacuuming = true
        Task {
            defer { isVacuuming = false }
            do {
                let (before, after) = try await storageService.vacuumDatabase()
                let freed = max(before - after, 0)
                let freedStr = ByteCountFormatter.string(fromByteCount: freed, countStyle: .file)
                let currentStr = ByteCountFormatter.string(fromByteCount: after, countStyle: .file)
                totalCount = await PasteSQLManager.manager.getTotalCount()
                alertTitle = "压缩完成"
                alertMessage = "已成功整理数据库碎片！释放了约 \(freedStr) 磁盘空间，当前物理占用为 \(currentStr)。"
                showAlert = true
            } catch {
                alertTitle = "压缩失败"
                alertMessage = error.localizedDescription
                showAlert = true
            }
        }
    }

    // MARK: - 导出数据库

    private func exportDatabase() {
        let panel = NSSavePanel()
        panel.title = String(localized: .storageExportPanelTitle)
        panel.nameFieldLabel = String(localized: .storageFileNameLabel)
        panel.nameFieldStringValue = "Clip_Backup_\(formattedDate()).sqlite3"
        panel.allowedContentTypes = [
            UTType(filenameExtension: "sqlite3") ?? .database
        ]
        panel.canCreateDirectories = true

        guard panel.runModal() == .OK, let url = panel.url else { return }

        isExporting = true

        let chipsData = try? JSONEncoder().encode(PasteUserDefaults.userCategoryChip)

        Task.detached(priority: .userInitiated) {
            let result = await PasteSQLManager.manager.exportDatabase(to: url, userChipsData: chipsData)

            await MainActor.run {
                isExporting = false
                if result.success {
                    log.info("数据库导出成功: \(url.lastPathComponent)")
                    alertTitle = result.message
                } else {
                    log.error("数据库导出失败: \(result.message)")
                    alertTitle = String(localized: .storageExportFailureTitle)
                    alertMessage = result.message
                }
                showAlert = true
            }
        }
    }

    // MARK: - 导入数据库

    private func importDatabase() {
        let panel = NSOpenPanel()
        panel.title = String(localized: .storageImportPanelTitle)
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [
            UTType(filenameExtension: "sqlite3") ?? .database
        ]

        let clipDataDir = URL.documentsDirectory.appending(path: "Clip")
        if FileManager.default.fileExists(atPath: clipDataDir.path) {
            panel.directoryURL = clipDataDir
        }

        guard panel.runModal() == .OK, let url = panel.url else { return }

        isImporting = true

        Task.detached(priority: .userInitiated) {
            let result = await PasteSQLManager.manager.importDatabase(from: url)

            await MainActor.run {
                isImporting = false

                if result.success {
                    log.info("数据库导入成功: \(result.message)")
                    alertTitle = String(localized: .storageImportSuccessTitle)
                    alertMessage = result.message

                    Task {
                        await PasteDataStore.main.resetDefaultList()
                        let count = await PasteSQLManager.manager.getTotalCount()
                        db.totalCount = count
                        totalCount = count
                        db.notifyCategoryChipsChanged()
                        await storageService.refreshDiskUsage()
                    }
                } else {
                    log.error("数据库导入失败: \(result.message)")
                    alertTitle = String(localized: .storageImportFailureTitle)
                    alertMessage = result.message.contains(
                        String(localized: .importCancelled)
                    )
                        ? String(localized: .storageImportCancelled)
                        : result.message
                }
                showAlert = true
            }
        }
    }

    private func formattedDate() -> String {
        let components = Calendar.current.dateComponents(
            [.year, .month, .day],
            from: Date()
        )
        let year = components.year ?? 0
        let month = (components.month ?? 0).formatted(
            .number.precision(.integerLength(2))
        )
        let day = (components.day ?? 0).formatted(
            .number.precision(.integerLength(2))
        )
        return "\(year)\(month)\(day)"
    }
}

// MARK: - 数据统计行

struct DataStatRow: View {
    let title: String
    let value: String

    var body: some View {
        HStack {
            Text(title)
                .font(.callout)
            Spacer()
            Text(value)
                .font(.callout)
        }
        .padding(.vertical, Const.space12)
    }
}

// MARK: - 数据操作行

struct DataActionRow: View {
    let title: String
    let subtitle: String
    let buttonTitle: String
    let isLoading: Bool
    let action: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: Const.space12) {
            VStack(alignment: .leading, spacing: Const.space4) {
                Text(title)
                    .font(.callout)
                Text(subtitle)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer()

            if isLoading {
                ProgressView()
                    .controlSize(.small)
            } else {
                SystemButton(title: buttonTitle, action: action)
            }
        }
        .padding(.vertical, Const.space12)
    }
}

// MARK: - 现代化数据类型占比色条

struct StorageBreakdownBarView: View {
    let proportions: [StorageTypeProportion]

    private var totalBytes: Int64 {
        max(proportions.reduce(0) { $0 + $1.totalBytes }, 1)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Const.space10) {
            HStack {
                Text("数据类型占用分布")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Text("共 \(proportions.count) 种类型")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            // 现代化分段胶囊轨道
            GeometryReader { geo in
                let availableWidth = max(geo.size.width, 100)
                let spacingTotal = CGFloat(max(proportions.count - 1, 0)) * 2.0
                let barWidth = max(availableWidth - spacingTotal, 10)

                HStack(spacing: 2) {
                    ForEach(proportions) { item in
                        let ratio = CGFloat(item.totalBytes) / CGFloat(totalBytes)
                        let width = max(barWidth * ratio, 6)
                        let percentStr = String(format: "%.1f%%", (Double(item.totalBytes) / Double(totalBytes)) * 100)

                        RoundedRectangle(cornerRadius: 3)
                            .fill(
                                LinearGradient(
                                    colors: [item.swiftUIColor, item.swiftUIColor.opacity(0.85)],
                                    startPoint: .top,
                                    endPoint: .bottom
                                )
                            )
                            .frame(width: width)
                            .help("\(item.displayName): \(item.formattedBytes) (\(percentStr) · \(item.count) 项)")
                    }
                }
            }
            .frame(height: 10)
            .background(Color.secondary.opacity(0.12))
            .clipShape(Capsule())

            // 现代化图例徽标网格
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 120), spacing: Const.space8)],
                alignment: .leading,
                spacing: Const.space8
            ) {
                ForEach(proportions.prefix(6)) { item in
                    let percent = Int(round((Double(item.totalBytes) / Double(totalBytes)) * 100))
                    HStack(spacing: 6) {
                        Circle()
                            .fill(item.swiftUIColor)
                            .frame(width: 8, height: 8)
                            .shadow(color: item.swiftUIColor.opacity(0.45), radius: 2, y: 1)

                        VStack(alignment: .leading, spacing: 1) {
                            Text(item.displayName)
                                .font(.caption2)
                                .fontWeight(.medium)
                                .lineLimit(1)
                            Text("\(item.formattedBytes) (\(percent)%)")
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(Color.secondary.opacity(0.06))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .help("\(item.displayName): \(item.count) 项记录")
                }
            }
        }
        .padding(.vertical, Const.space4)
    }
}

#Preview {
    StorageSettingView()
        .frame(width: Const.settingWidth - 150, height: Const.settingHeight)
}
