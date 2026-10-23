//
//  SyncSettingView.swift
//  Clipboard
//
//  现代化 WebDAV 端到端加密同步设置视图
//

import SwiftUI

enum WebDAVProviderPreset: String, CaseIterable, Identifiable {
    case custom = "custom"
    case jianguoyun = "jianguoyun"
    case nextcloud = "nextcloud"
    case synology = "synology"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .custom: return "自定义 WebDAV"
        case .jianguoyun: return "坚果云 (Jianguoyun)"
        case .nextcloud: return "Nextcloud / ownCloud"
        case .synology: return "群晖 (Synology NAS)"
        }
    }

    var defaultURL: String {
        switch self {
        case .custom: return "https://"
        case .jianguoyun: return "https://dav.jianguoyun.com/dav/"
        case .nextcloud: return "https://your-domain/remote.php/dav/files/username/"
        case .synology: return "https://your-nas-ip:5006/home/"
        }
    }
}

struct SyncSettingView: View {
    @ObservedObject private var engine = SyncEngine.shared

    @AppStorage("sync_enabled") private var syncEnabled: Bool = false
    @AppStorage("sync_webdav_url") private var serverURL: String = ""
    @AppStorage("sync_webdav_username") private var username: String = ""
    @AppStorage("sync_only_pinned") private var onlySyncPinned: Bool = true
    @AppStorage("sync_auto_enabled") private var autoSyncEnabled: Bool = true
    @AppStorage("sync_preset") private var selectedPreset: String = WebDAVProviderPreset.custom.rawValue

    @State private var passwordInput: String = ""
    @State private var passphraseInput: String = ""
    @State private var isTesting = false
    @State private var testResult: String?
    @State private var testSuccess: Bool?
    @State private var showOverwriteConfirmation = false

    var body: some View {
        let content = ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 20) {
                // MARK: - 主总开关卡片
                VStack(alignment: .leading, spacing: 0) {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("启用 WebDAV 云端同步")
                                .font(.headline)
                            Text("在多台 Mac 设备之间通过 WebDAV 安全同步剪贴板资产。")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Toggle("", isOn: $syncEnabled)
                            .toggleStyle(.switch)
                            .labelsHidden()
                            .onChange(of: syncEnabled) { _, newValue in
                                if newValue {
                                    Task { await engine.triggerSync() }
                                }
                            }
                    }
                    .padding(.vertical, Const.space12)
                }
                .padding(.horizontal, Const.space16)
                .settingsStyle()

                // MARK: - 详细配置区域（由主开关驱动）
                VStack(alignment: .leading, spacing: 20) {
                    // 1. 服务器连接配置卡片
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Text("WebDAV 同步服务器")
                                .font(.headline)
                                .bold()
                            Spacer()
                        }

                        // 预设选择器
                        HStack {
                            Text("服务商预设")
                                .font(.callout)
                                .frame(width: 90, alignment: .leading)
                            Picker("", selection: $selectedPreset) {
                                ForEach(WebDAVProviderPreset.allCases) { preset in
                                    Text(preset.displayName).tag(preset.rawValue)
                                }
                            }
                            .labelsHidden()
                            .onChange(of: selectedPreset) { _, newVal in
                                if let preset = WebDAVProviderPreset(rawValue: newVal), preset != .custom, serverURL.isEmpty || serverURL == "https://" {
                                    serverURL = preset.defaultURL
                                }
                            }
                        }

                        // 服务器地址
                        HStack {
                            Text("服务器地址")
                                .font(.callout)
                                .frame(width: 90, alignment: .leading)
                            TextField("https://dav.example.com/", text: $serverURL)
                                .textFieldStyle(.roundedBorder)
                        }

                        // 账号
                        HStack {
                            Text("账号")
                                .font(.callout)
                                .frame(width: 90, alignment: .leading)
                            TextField("用户名或邮箱", text: $username)
                                .textFieldStyle(.roundedBorder)
                        }

                        // 应用密码
                        HStack {
                            Text("密码 / Token")
                                .font(.callout)
                                .frame(width: 90, alignment: .leading)
                            SecureField("WebDAV 密码或应用令牌", text: $passwordInput)
                                .textFieldStyle(.roundedBorder)
                                .onChange(of: passwordInput) { _, newValue in
                                    try? SyncKeychainManager.shared.saveWebDAVPassword(newValue)
                                }
                        }

                        Divider()
                            .padding(.vertical, 4)

                        // 测试连接按钮与状态
                        HStack {
                            if let testResult {
                                HStack(spacing: 4) {
                                    Image(systemName: testSuccess == true ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                                        .foregroundStyle(testSuccess == true ? .green : .red)
                                    Text(testResult)
                                        .font(.caption)
                                        .foregroundStyle(testSuccess == true ? Color.primary : Color.red)
                                }
                            }

                            Spacer()

                            if isTesting {
                                ProgressView().controlSize(.small)
                            }

                            Button("测试连接") {
                                runConnectionTest()
                            }
                            .disabled(serverURL.isEmpty || username.isEmpty || passwordInput.isEmpty || isTesting)
                        }
                    }
                    .padding(Const.space16)
                    .settingsStyle()

                    // 2. 端到端密码加密卡片
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Label("端到端密码加密 (E2EE)", systemImage: "lock.shield")
                                .font(.headline)
                                .bold()
                            Spacer()
                        }

                        Text("剪贴板内容在离开您的 Mac 之前，均会使用 AES-256 算法进行本地强加密；WebDAV 服务器仅存储密文，无法解读您的任何复制内容。")
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        HStack {
                            Text("同步主密码")
                                .font(.callout)
                                .frame(width: 90, alignment: .leading)
                            SecureField("输入所有设备共享的同步密码", text: $passphraseInput)
                                .textFieldStyle(.roundedBorder)
                                .onChange(of: passphraseInput) { _, newValue in
                                    try? SyncKeychainManager.shared.saveSyncPassphrase(newValue)
                                }
                        }

                        Text("请在所有需要同步的设备上输入完全相同的密码。若密码遗失，云端密文将无法解密。")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                    .padding(Const.space16)
                    .settingsStyle()

                    // 3. 同步控制与策略卡片
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Text("同步策略与状态")
                                .font(.headline)
                                .bold()
                            Spacer()
                        }

                        // 仅同步收藏
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("仅同步收藏和分组条目 (推荐)")
                                    .font(.callout)
                                Text("日常零散的剪贴流水仅保留在本机，只有添加了分组或收藏的重要条目才会被加密同步。")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Toggle("", isOn: $onlySyncPinned)
                                .labelsHidden()
                        }

                        Divider()

                        // 自动增量同步
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("后台 15 秒自动增量同步")
                                    .font(.callout)
                                Text("本地内容产生变化 15 秒后，自动聚合为一次轻量增量加密上传，低能耗低流量。")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Toggle("", isOn: $autoSyncEnabled)
                                .labelsHidden()
                        }

                        Divider()

                        // 当前状态与手动同步
                        HStack {
                            HStack(spacing: 6) {
                                Circle()
                                    .fill(statusColor)
                                    .frame(width: 8, height: 8)
                                Text(engine.currentState.displayText)
                                    .font(.callout)
                                    .foregroundStyle(.secondary)
                            }

                            Spacer()

                            Button(action: {
                                Task {
                                    await engine.triggerSync()
                                }
                            }) {
                                HStack(spacing: 4) {
                                    if case .syncing = engine.currentState {
                                        ProgressView().controlSize(.small)
                                    } else {
                                        Image(systemName: "arrow.triangle.2.circlepath")
                                    }
                                    Text("立即同步")
                                }
                            }
                            .disabled(serverURL.isEmpty || username.isEmpty || passphraseInput.isEmpty || engine.currentState == .syncing)
                        }
                    }
                    .padding(Const.space16)
                    .settingsStyle()

                    // 4. 云端已备份资产看板与还原卡片
                    VStack(alignment: .leading, spacing: 14) {
                        HStack {
                            Label("云端已备份资产看板", systemImage: "internaldrive.fill")
                                .font(.headline)
                                .bold()
                            Spacer()

                            if engine.isFetchingSummary {
                                ProgressView().controlSize(.small)
                            } else {
                                Button(action: {
                                    Task { await engine.fetchCloudSummary() }
                                }) {
                                    HStack(spacing: 4) {
                                        Image(systemName: "arrow.clockwise")
                                        Text("刷新概览")
                                    }
                                    .font(.caption)
                                }
                                .buttonStyle(.borderless)
                                .disabled(serverURL.isEmpty || username.isEmpty || passphraseInput.isEmpty || engine.isFetchingSummary)
                            }
                        }

                        if let summary = engine.syncSummary {
                            HStack(alignment: .firstTextBaseline, spacing: 4) {
                                Text("云端已安全加密备份共")
                                    .font(.callout)
                                    .foregroundStyle(.secondary)
                                Text("\(summary.totalCount)")
                                    .font(.title3)
                                    .bold()
                                    .foregroundStyle(.primary)
                                Text("条记录")
                                    .font(.callout)
                                    .foregroundStyle(.secondary)
                            }

                            // 分组 / 标签细分胶囊条
                            if !summary.groupCounts.isEmpty {
                                VStack(alignment: .leading, spacing: 6) {
                                    Text("按分组/标签已备份:")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)

                                    ScrollView(.horizontal, showsIndicators: false) {
                                        HStack(spacing: 8) {
                                            ForEach(summary.groupCounts) { item in
                                                HStack(spacing: 5) {
                                                    Circle()
                                                        .fill(chipColor(for: item))
                                                        .frame(width: 8, height: 8)
                                                    Text(item.name)
                                                        .font(.caption)
                                                    Text("\(item.count)")
                                                        .font(.caption)
                                                        .bold()
                                                        .padding(.horizontal, 4)
                                                        .padding(.vertical, 1)
                                                        .background(Color.primary.opacity(0.08))
                                                        .clipShape(Capsule())
                                                }
                                                .padding(.horizontal, 8)
                                                .padding(.vertical, 4)
                                                .background(Color(NSColor.controlBackgroundColor))
                                                .cornerRadius(6)
                                                .overlay(
                                                    RoundedRectangle(cornerRadius: 6)
                                                        .stroke(Color.secondary.opacity(0.15), lineWidth: 1)
                                                )
                                            }
                                        }
                                    }
                                }
                            }

                            // 媒体类型胶囊
                            if !summary.typeCounts.isEmpty {
                                HStack(spacing: 8) {
                                    ForEach(summary.typeCounts) { t in
                                        HStack(spacing: 4) {
                                            Text(t.typeName)
                                                .font(.caption2)
                                                .foregroundStyle(.secondary)
                                            Text("\(t.count)")
                                                .font(.caption2)
                                                .bold()
                                        }
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 2)
                                        .background(Color.secondary.opacity(0.1))
                                        .cornerRadius(4)
                                    }
                                }
                            }
                        } else {
                            HStack(spacing: 6) {
                                Image(systemName: "icloud.slash")
                                    .foregroundStyle(.secondary)
                                Text("尚未获取到云端资产统计，连接同步后将在此呈现详细看板。")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.vertical, 2)
                        }

                        Divider()

                        // MARK: - 还原与恢复操作
                        VStack(alignment: .leading, spacing: 12) {
                            Text("还原与恢复数据")
                                .font(.subheadline)
                                .bold()

                            // 智能合并还原（推荐模式）
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("智能拉取还原 (安全合并 · 推荐)")
                                        .font(.callout)
                                    Text("仅补充本地缺失的云端条目，严格保留本地所有已添加的新内容，不丢失任何数据。")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                Button(action: {
                                    Task {
                                        _ = await engine.restoreFromCloud(overwriteLocal: false)
                                    }
                                }) {
                                    HStack(spacing: 4) {
                                        if engine.isRestoring {
                                            ProgressView().controlSize(.small)
                                        } else {
                                            Image(systemName: "arrow.down.doc")
                                        }
                                        Text("智能还原")
                                    }
                                }
                                .disabled(serverURL.isEmpty || username.isEmpty || passphraseInput.isEmpty || engine.isRestoring || engine.currentState == .syncing)
                            }

                            Divider()

                            // 完全覆盖本地（高级危险模式）
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("完全以云端覆盖本地 (危险)")
                                        .font(.callout)
                                        .foregroundStyle(.red)
                                    Text("清空本地现有记录，完全克隆云端备份。本地未同步的新增内容将被抹掉且不可逆。")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                Button("覆盖本地...") {
                                    showOverwriteConfirmation = true
                                }
                                .foregroundStyle(.red)
                                .disabled(serverURL.isEmpty || username.isEmpty || passphraseInput.isEmpty || engine.isRestoring || engine.currentState == .syncing)
                            }

                            if let msg = engine.restoreMessage {
                                HStack(spacing: 6) {
                                    Image(systemName: "info.circle.fill")
                                        .foregroundStyle(.blue)
                                    Text(msg)
                                        .font(.caption)
                                }
                                .padding(.top, 2)
                            }
                        }
                    }
                    .padding(Const.space16)
                    .settingsStyle()
                }
                .disabled(!syncEnabled)
                .opacity(syncEnabled ? 1.0 : 0.6)
                .animation(.easeInOut(duration: 0.2), value: syncEnabled)

                Spacer(minLength: 20)
            }
            .padding([.horizontal, .bottom], Const.space24)
        }
        .alert("完全用云端覆盖本地？", isPresented: $showOverwriteConfirmation) {
            Button("抹掉并覆盖本地", role: .destructive) {
                Task {
                    _ = await engine.restoreFromCloud(overwriteLocal: true)
                }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("此操作将完全抹掉本地所有剪贴板记录，并以云端备份为准重新导入。本地任何尚未同步的新增内容都将永久丢失。")
        }
        .onAppear {
            loadCredentials()
        }

        if #available(macOS 26.0, *) {
            content.scrollEdgeEffectStyle(.soft, for: .top)
        } else {
            content
        }
    }

    private var statusColor: Color {
        guard syncEnabled else { return .gray }
        switch engine.currentState {
        case .disabled, .idle: return .gray
        case .syncing: return .blue
        case .success: return .green
        case .failed: return .red
        }
    }

    private func chipColor(for item: SyncGroupCount) -> Color {
        if item.groupId == -1 {
            return .gray
        }
        if let hex = item.colorHex, !hex.isEmpty {
            return Color(hex: hex)
        }
        return .blue
    }

    private func loadCredentials() {
        passwordInput = SyncKeychainManager.shared.loadWebDAVPassword() ?? ""
        passphraseInput = SyncKeychainManager.shared.loadSyncPassphrase() ?? ""
    }

    private func runConnectionTest() {
        guard let url = URL(string: serverURL) else {
            testResult = "URL 格式不合法"
            testSuccess = false
            return
        }
        isTesting = true
        testResult = nil

        let client = WebDAVClient(baseURL: url, username: username, password: passwordInput)
        Task {
            do {
                let (_, latency) = try await client.testConnection()
                await MainActor.run {
                    self.isTesting = false
                    self.testSuccess = true
                    self.testResult = String(format: "连接成功 (延时: %.0f ms)", latency)
                }
            } catch {
                await MainActor.run {
                    self.isTesting = false
                    self.testSuccess = false
                    self.testResult = error.localizedDescription
                }
            }
        }
    }
}
