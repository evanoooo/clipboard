//
//  PasteMigrationSheet.swift
//  Clipboard
//
//  Created by crown on 2026/10/23.
//

import AppKit
import SwiftUI
import UniformTypeIdentifiers

private enum MigrationPhase {
    case ready
    case scanning
    case migrating
    case finished
    case failed
}

struct PasteMigrationSheet: View {
    @Environment(\.dismiss) private var dismiss

    @State private var phase: MigrationPhase = .ready
    @State private var selectedDatabaseURL: URL? = nil
    @State private var scanInfo: PasteMigrationScanInfo? = nil
    @State private var progressInfo: PasteMigrationProgress? = nil
    @State private var migrationResult: PasteMigrationResult? = nil
    @State private var errorMessage: String? = nil

    private let service = PasteMigrationService.shared

    var body: some View {
        VStack(spacing: 0) {
            // MARK: - 顶部导航条
            headerView

            Divider()

            // MARK: - 主体内容
            ScrollView(.vertical) {
                VStack(spacing: Const.space16) {
                    switch phase {
                    case .ready, .scanning:
                        readyAndScanView
                    case .migrating:
                        migratingView
                    case .finished:
                        finishedView
                    case .failed:
                        failedView
                    }
                }
                .padding(Const.space20)
            }

            Divider()

            // MARK: - 底部操作栏
            footerView
        }
        .frame(width: 540, height: 500)
        .task {
            await autoDetectAndScan()
        }
    }

    // MARK: - 顶部视图

    private var headerView: some View {
        HStack(alignment: .center, spacing: Const.space12) {
            Image(systemName: "arrow.triangle.2.circlepath.doc.on.clipboard")
                .font(.system(size: 24))
                .foregroundStyle(Color.accentColor)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: Const.space8) {
                    Text("从 Paste.app 导入历史记录")
                        .font(.headline)
                        .bold()

                    // Beta 标签
                    Text(verbatim: "Beta")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.orange)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.orange.opacity(0.15))
                        .clipShape(Capsule())
                }

                Text("扫描本地 Paste 数据库并无缝迁移历史条目，自动保留来源应用与时间线。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if phase != .migrating {
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title2)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, Const.space20)
        .padding(.vertical, Const.space14)
    }

    // MARK: - 准备与扫描阶段视图

    private var readyAndScanView: some View {
        VStack(alignment: .leading, spacing: Const.space16) {
            // 数据库路径选择卡片
            VStack(alignment: .leading, spacing: Const.space8) {
                HStack {
                    Text("Paste 数据库位置")
                        .font(.subheadline)
                        .bold()
                    Spacer()
                    Button("选择其他文件...") {
                        chooseCustomDatabase()
                    }
                    .buttonStyle(.link)
                    .controlSize(.small)
                }

                HStack(spacing: Const.space8) {
                    Image(systemName: selectedDatabaseURL != nil ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                        .foregroundStyle(selectedDatabaseURL != nil ? Color.green : Color.orange)

                    Text(selectedDatabaseURL?.path ?? "未检测到默认数据库，请手动指定")
                        .font(.caption)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .foregroundStyle(.secondary)
                }
                .padding(Const.space10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.secondary.opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }

            // 预检扫描摘要
            if phase == .scanning {
                HStack(spacing: Const.space10) {
                    ProgressView()
                        .controlSize(.small)
                    Text("正在快速预检数据库内容...")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.vertical, Const.space20)
            } else if let scan = scanInfo {
                VStack(alignment: .leading, spacing: Const.space10) {
                    Text("预检摘要")
                        .font(.subheadline)
                        .bold()

                    HStack(spacing: Const.space12) {
                        statPill(title: "待迁移条目", value: "\(scan.totalItemCount) 条", icon: "doc.on.doc")
                        statPill(title: "来源应用", value: "\(scan.sourceAppCount) 个", icon: "app.badge")
                        statPill(title: "文件体积", value: scan.formattedSize, icon: "internaldrive")
                    }

                    if scan.earliestDate != nil {
                        HStack(spacing: Const.space6) {
                            Image(systemName: "calendar")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text("时间跨度：\(scan.formattedDateRange)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.top, 2)
                    }
                }
                .padding(Const.space12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.accentColor.opacity(0.06))
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }

            // 安全说明与保护承诺
            VStack(alignment: .leading, spacing: Const.space8) {
                Text("安全与保护机制")
                    .font(.subheadline)
                    .bold()

                VStack(alignment: .leading, spacing: Const.space6) {
                    safetyRow(icon: "lock.shield", text: "只读模式：全程只读访问，绝不修改 Paste.app 任何原始文件")
                    safetyRow(icon: "arrow.counterclockwise.circle", text: "自动备份：开始写入前自动将当前数据库完整快照备份到本地")
                    safetyRow(icon: "checkmark.seal", text: "智能去重：严格比对 SHA-256 指纹，跳过已有记录，保留您的已有标签")
                    safetyRow(icon: "clock.arrow.circlepath", text: "时间线重序：按原创建时间归档历史，不会抢占最新剪贴板位置")
                }
            }
            .padding(Const.space12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.secondary.opacity(0.05))
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
    }

    private func statPill(title: String, value: String, icon: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text(title)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Text(value)
                .font(.headline)
                .bold()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Const.space8)
        .background(Color.secondary.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    private func safetyRow(icon: String, text: String) -> some View {
        HStack(alignment: .top, spacing: Const.space8) {
            Image(systemName: icon)
                .font(.caption)
                .foregroundStyle(Color.accentColor)
                .frame(width: 16)
                .padding(.top, 1)

            Text(text)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - 迁移进行中视图

    private var migratingView: some View {
        VStack(spacing: Const.space20) {
            Spacer(minLength: 20)

            ProgressView()
                .scaleEffect(1.2)

            VStack(spacing: Const.space8) {
                Text(progressInfo?.statusMessage ?? "正在迁移...")
                    .font(.headline)
                    .bold()

                if let progress = progressInfo {
                    ProgressView(value: progress.fractionCompleted)
                        .progressViewStyle(.linear)
                        .frame(width: 380)

                    HStack {
                        Text("已导入: \(progress.importedCount) 条")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text("重复跳过: \(progress.duplicateCount) 条")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .frame(width: 380)
                }
            }

            Text("写入采用分批事务与安全断点机制，请勿强制退出应用。")
                .font(.caption2)
                .foregroundStyle(.secondary)

            Spacer(minLength: 20)
        }
        .frame(maxWidth: .infinity, minHeight: 280)
    }

    // MARK: - 迁移完成视图

    private var finishedView: some View {
        VStack(spacing: Const.space16) {
            Spacer(minLength: 10)

            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 48))
                .foregroundStyle(Color.green)

            Text("迁移完成！")
                .font(.title2)
                .bold()

            if let res = migrationResult {
                VStack(spacing: Const.space8) {
                    HStack(spacing: Const.space12) {
                        statPill(title: "成功导入", value: "\(res.importedCount) 条", icon: "tray.and.arrow.down.fill")
                        statPill(title: "重复跳过", value: "\(res.duplicateCount) 条", icon: "doc.on.doc.fill")
                        statPill(title: "跳过异常", value: "\(res.skippedCount) 条", icon: "slash.circle")
                    }

                    if let backupURL = res.autoBackupURL {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("已在导入前自动创建安全备份快照：")
                                .font(.caption2)
                                .foregroundStyle(.secondary)

                            HStack {
                                Text(backupURL.lastPathComponent)
                                    .font(.caption)
                                    .bold()
                                    .lineLimit(1)
                                Spacer()
                                Button("在访达中定位") {
                                    NSWorkspace.shared.activateFileViewerSelecting([backupURL])
                                }
                                .buttonStyle(.link)
                                .controlSize(.small)
                            }
                        }
                        .padding(Const.space10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.secondary.opacity(0.08))
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                    }
                }
                .frame(width: 440)
            }

            Spacer(minLength: 10)
        }
        .frame(maxWidth: .infinity, minHeight: 280)
    }

    // MARK: - 迁移失败视图

    private var failedView: some View {
        VStack(spacing: Const.space16) {
            Spacer(minLength: 20)

            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 48))
                .foregroundStyle(Color.red)

            Text("迁移遇到问题")
                .font(.headline)
                .bold()

            Text(errorMessage ?? "未知错误")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 400)

            Spacer(minLength: 20)
        }
        .frame(maxWidth: .infinity, minHeight: 280)
    }

    // MARK: - 底部操作栏

    private var footerView: some View {
        HStack {
            Spacer()

            switch phase {
            case .ready, .scanning:
                Button("取消") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)

                Button("开始导入") {
                    startMigration()
                }
                .buttonStyle(.borderedProminent)
                .disabled(scanInfo == nil || (scanInfo?.totalItemCount ?? 0) == 0 || phase == .scanning)

            case .migrating:
                EmptyView()

            case .finished:
                Button("完成") {
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)

            case .failed:
                Button("取消") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)

                Button("重试") {
                    phase = .ready
                    if let url = selectedDatabaseURL {
                        Task { await scanDatabase(url: url) }
                    }
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(.horizontal, Const.space20)
        .padding(.vertical, Const.space12)
    }

    // MARK: - 交互逻辑

    private func autoDetectAndScan() async {
        if let defaultURL = service.detectDefaultDatabase() {
            selectedDatabaseURL = defaultURL
            await scanDatabase(url: defaultURL)
        }
    }

    private func chooseCustomDatabase() {
        let panel = NSOpenPanel()
        panel.title = "选择 Paste.app 数据库文件 (db.sqlite)"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [
            UTType(filenameExtension: "sqlite") ?? .database,
            UTType(filenameExtension: "sqlite3") ?? .database,
            .database
        ]

        if panel.runModal() == .OK, let url = panel.url {
            selectedDatabaseURL = url
            Task {
                await scanDatabase(url: url)
            }
        }
    }

    private func scanDatabase(url: URL) async {
        phase = .scanning
        do {
            let scan = try await service.scan(databaseURL: url)
            scanInfo = scan
            phase = .ready
        } catch {
            errorMessage = error.localizedDescription
            phase = .failed
        }
    }

    private func startMigration() {
        guard let url = selectedDatabaseURL else { return }
        phase = .migrating

        Task {
            do {
                let result = try await service.migrate(from: url) { progress in
                    Task { @MainActor in
                        self.progressInfo = progress
                    }
                }
                self.migrationResult = result
                self.phase = .finished
            } catch {
                self.errorMessage = error.localizedDescription
                self.phase = .failed
            }
        }
    }
}
