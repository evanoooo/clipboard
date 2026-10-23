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
    @State private var showPasteMigration = false
    @State private var showAlert = false
    @State private var alertTitle = ""
    @State private var alertMessage = ""

    // 软配额配置状态
    @State private var selectedQuotaThreshold: Int64 = PasteUserDefaults.softQuotaBytes
    @State private var selectedAgingPolicy: String = PasteUserDefaults.softQuotaAgingPolicy
    @State private var enableIdleAutoMaintenance: Bool = PasteUserDefaults.enableIdleAutoMaintenance
    @State private var selectedLogLevel: String = PasteUserDefaults.appLogLevel
    @State private var selectedMmapSizeMB: Int = PasteUserDefaults.sqliteMmapSizeMB
    @State private var copiedReport = false

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

                // MARK: - 智能软配额与自动维护
                VStack(alignment: .leading, spacing: Const.space12) {
                    VStack(alignment: .leading, spacing: Const.space2) {
                        Text("智能软配额与自动维护")
                            .font(.headline)
                            .bold()
                        Text("设定弹性容量警戒线，超额时智能识别陈旧临时大图，绝不误删重要内容。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    // 水位健康度彩色进度胶囊
                    if let quota = storageService.quotaStatus, quota.isEnabled {
                        VStack(spacing: Const.space6) {
                            HStack {
                                HStack(spacing: 4) {
                                    Text("当前占用")
                                        .foregroundStyle(.secondary)
                                    Text(quota.formattedCurrent)
                                        .bold()
                                        .foregroundStyle(quota.isExceeded ? Color.red : (quota.isWarning ? Color.orange : Color.primary))
                                }
                                .font(.caption)

                                Spacer()

                                HStack(spacing: 4) {
                                    Text(quota.isExceeded ? "已超出警戒线" : "软配额上限")
                                        .foregroundStyle(quota.isExceeded ? Color.red : Color.secondary)
                                    Text("\(quota.formattedQuota) (\(Int(min(quota.ratio, 9.99) * 100))%)")
                                        .foregroundStyle(.secondary)
                                }
                                .font(.caption)
                            }

                            GeometryReader { g in
                                ZStack(alignment: .leading) {
                                    Capsule()
                                        .fill(Color.secondary.opacity(0.15))
                                    Capsule()
                                        .fill(quota.isExceeded ? Color.red : (quota.isWarning ? Color.orange : Color.accentColor))
                                        .frame(width: max(min(CGFloat(quota.ratio) * g.size.width, g.size.width), 4))
                                }
                            }
                            .frame(height: 6)
                        }
                        .padding(.vertical, Const.space2)
                    }

                    // 智能瘦身建议条（当发现有符合老化条件的旧图时）
                    if let quota = storageService.quotaStatus, quota.candidateItemCount > 0 {
                        HStack(spacing: Const.space10) {
                            Image(systemName: "lightbulb.max.fill")
                                .font(.title3)
                                .foregroundStyle(.orange)

                            VStack(alignment: .leading, spacing: 2) {
                                Text("发现 \(quota.candidateItemCount) 项陈旧临时大图")
                                    .font(.callout)
                                    .bold()
                                Text("预计可安全释放 \(quota.formattedCandidateFreed) 空间（加星收藏、分类标签与纯文本 100% 免疫）")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }

                            Spacer()

                            Button("查看并清理") {
                                showInspector = true
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            .disabled(storageService.isEvicting)

                            Button {
                                performRecommendedEviction()
                            } label: {
                                if storageService.isEvicting {
                                    ProgressView().controlSize(.small)
                                } else {
                                    Text("一键瘦身")
                                }
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                            .disabled(storageService.isEvicting)
                        }
                        .padding(Const.space12)
                        .background(Color.orange.opacity(0.08))
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                    }

                    Divider()

                    // 配额警戒线选择
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("容量警戒线")
                                .font(.callout)
                            Text("超出该容量时激活智能建议，不影响新内容复制")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Picker("", selection: $selectedQuotaThreshold) {
                            ForEach(SoftQuotaThreshold.allCases) { threshold in
                                Text(threshold.displayName).tag(threshold.rawValue)
                            }
                        }
                        .labelsHidden()
                        .frame(width: 160)
                        .onChange(of: selectedQuotaThreshold) { _, newValue in
                            PasteUserDefaults.softQuotaBytes = newValue
                            PasteUserDefaults.enableSoftQuota = newValue > 0
                            Task {
                                await storageService.refreshQuotaStatus()
                            }
                        }
                    }

                    Divider()

                    // 老化排查范围选择
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("老化排查范围")
                                .font(.callout)
                            Text("仅对该期限之前且未加星收藏的图片进行淘汰审查")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Picker("", selection: $selectedAgingPolicy) {
                            ForEach(SoftQuotaAgingPolicy.allCases) { policy in
                                Text(policy.displayName).tag(policy.rawValue)
                            }
                        }
                        .labelsHidden()
                        .frame(width: 210)
                        .onChange(of: selectedAgingPolicy) { _, newValue in
                            PasteUserDefaults.softQuotaAgingPolicy = newValue
                            Task {
                                await storageService.refreshQuotaStatus()
                            }
                        }
                    }

                    Divider()

                    // 系统空闲时自动维护瘦身
                    Toggle(isOn: $enableIdleAutoMaintenance) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("系统空闲时自动维护瘦身")
                                .font(.callout)
                            Text("在 Mac 闲置期间以最低能耗在后台安全清理未收藏旧图，并整理碎片空间。")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .toggleStyle(.switch)
                    .onChange(of: enableIdleAutoMaintenance) { _, newValue in
                        PasteUserDefaults.enableIdleAutoMaintenance = newValue
                    }
                }
                .padding(.horizontal, Const.space16)
                .padding(.vertical, Const.space12)
                .settingsStyle()

                // MARK: - 空间透视与自主整理
                VStack(alignment: .leading, spacing: 0) {
                    DataActionRow(
                        title: "空间透视与批量管理",
                        subtitle: "按类型分类透视前 100 个大文件，提供大图悬浮预览与安全批量清理",
                        buttonTitle: "打开透视器",
                        isLoading: false
                    ) {
                        showInspector = true
                    }

                    Divider()

                    DataActionRow(
                        title: "压缩整理数据库 (VACUUM)",
                        subtitle: "回收删除条目后遗留的碎片空洞，释放物理磁盘占用",
                        buttonTitle: "立即整理",
                        isLoading: isVacuuming
                    ) {
                        vacuumDatabase()
                    }
                }
                .padding(.horizontal, Const.space16)
                .settingsStyle()

                // MARK: - 备份与恢复
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

                    Divider()

                    HStack(alignment: .center, spacing: Const.space12) {
                        VStack(alignment: .leading, spacing: Const.space4) {
                            HStack(spacing: Const.space8) {
                                Text("从 Paste.app 迁移历史记录")
                                    .font(.callout)

                                Text(verbatim: "Beta")
                                    .font(.system(size: 10, weight: .bold))
                                    .foregroundStyle(.orange)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(Color.orange.opacity(0.15))
                                    .clipShape(Capsule())
                            }

                            Text("智能扫描并导入 Paste 本地历史数据库，自动保留来源应用、分类与时间线，支持严格防重。")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }

                        Spacer()

                        SystemButton(title: "开始导入") {
                            showPasteMigration = true
                        }
                    }
                    .padding(.vertical, Const.space12)
                }
                .padding(.horizontal, Const.space16)
                .settingsStyle()

                // MARK: - 数据库性能与内存映射
                VStack(alignment: .leading, spacing: 0) {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("数据库内存映射 (mmap)")
                                .font(.callout)
                            Text("控制 SQLite 数据库在虚拟内存中的映射上限，整库映射可实现零拷贝极速检索；修改后即时生效。")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Picker("", selection: $selectedMmapSizeMB) {
                            ForEach(SQLiteMmapThreshold.allCases) { threshold in
                                Text(threshold.displayName).tag(threshold.rawValue)
                            }
                        }
                        .labelsHidden()
                        .frame(width: 170)
                        .onChange(of: selectedMmapSizeMB) { _, newValue in
                            PasteUserDefaults.sqliteMmapSizeMB = newValue
                            Task {
                                await PasteSQLManager.manager.setMmapSizeMB(newValue)
                                await PasteReadStore.shared.setMmapSizeMB(newValue)
                            }
                        }
                    }
                    .padding(.vertical, Const.space12)
                }
                .padding(.horizontal, Const.space16)
                .settingsStyle()

                // MARK: - 诊断与日志
                VStack(alignment: .leading, spacing: 0) {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("日志记录级别")
                                .font(.callout)
                            Text("控制输出到本地 log 文件的详细程度，支持即时动态生效")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Picker("", selection: $selectedLogLevel) {
                            ForEach(LogLevel.allCases) { level in
                                Text(level.displayName).tag(level.rawValue)
                            }
                        }
                        .labelsHidden()
                        .frame(width: 170)
                        .onChange(of: selectedLogLevel) { _, newValue in
                            PasteUserDefaults.appLogLevel = newValue
                            if let level = LogLevel(rawValue: newValue) {
                                AppLogger.shared.setMinimumLogLevel(level)
                            }
                        }
                    }
                    .padding(.vertical, Const.space12)

                    Divider()

                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("日志文件管理")
                                .font(.callout)
                            Text(copiedReport ? "已复制诊断报告至剪贴板！" : "日志保存在 ~/Library/Application Support/com.crown.clipboard/logs")
                                .font(.caption2)
                                .foregroundStyle(copiedReport ? Color.green : Color.secondary)
                        }
                        Spacer()
                        HStack(spacing: Const.space8) {
                            Button(copiedReport ? "已复制" : "复制诊断") {
                                let report = AppLogger.shared.exportDiagnosticReport()
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(report, forType: .string)
                                copiedReport = true
                                DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                                    copiedReport = false
                                }
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)

                            Button("在访达中显示") {
                                AppLogger.shared.openLogsDirectory()
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                        }
                    }
                    .padding(.vertical, Const.space12)
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
            selectedQuotaThreshold = PasteUserDefaults.softQuotaBytes
            selectedAgingPolicy = PasteUserDefaults.softQuotaAgingPolicy
            enableIdleAutoMaintenance = PasteUserDefaults.enableIdleAutoMaintenance
            selectedLogLevel = PasteUserDefaults.appLogLevel
            await storageService.refreshDiskUsage()
        }
        .sheet(isPresented: $showInspector) {
            StorageInspectorSheet()
        }
        .sheet(isPresented: $showPasteMigration) {
            PasteMigrationSheet()
        }
        .onChange(of: showPasteMigration) { _, isPresented in
            if !isPresented {
                Task {
                    totalCount = await PasteSQLManager.manager.getTotalCount()
                    await storageService.refreshDiskUsage()
                }
            }
        }
        .alert(alertTitle, isPresented: $showAlert) {
            Button(.commonConfirm, role: .cancel) {}
        } message: {
            Text(alertMessage)
        }
    }

    // MARK: - 执行智能瘦身

    private func performRecommendedEviction() {
        Task {
            do {
                let freed = try await storageService.applyRecommendedEviction()
                let freedStr = ByteCountFormatter.string(fromByteCount: freed, countStyle: .file)
                totalCount = await PasteSQLManager.manager.getTotalCount()
                alertTitle = "瘦身完成"
                alertMessage = "已安全清理未收藏临时旧图，共释放 \(freedStr) 数据。加星收藏与纯文本记录完好无损。"
                showAlert = true
            } catch {
                alertTitle = "操作失败"
                alertMessage = error.localizedDescription
                showAlert = true
            }
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
