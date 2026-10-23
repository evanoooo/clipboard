//
//  AboutSettingView.swift
//  Clipboard
//
//  Created by crown on 2025/11/11.
//

import AppKit
import Sparkle
import SwiftUI

struct AboutSettingView: View {
    @State private var copiedVersionFeedback = false
    @State private var updateManager = UpdateManager.shared

    private var appName: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String
            ?? "Clipboard"
    }

    private var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString")
            as? String ?? "2.3.0"
    }

    private var buildNumber: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
            ?? "888"
    }

    private var commitHash: String {
        Bundle.main.object(forInfoDictionaryKey: "GitCommitHash") as? String ?? "13cff85"
    }

    private var versionDisplay: String {
        "\(appVersion) (\(buildNumber) · \(commitHash))"
    }

    private let currentYear = Calendar.current.component(.year, from: Date())

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 24)

            // 应用图标与基本信息
            VStack(spacing: 10) {
                if let appIcon = NSImage(named: "AppIcon") {
                    Image(nsImage: appIcon)
                        .resizable()
                        .frame(width: 80, height: 80)
                        .shadow(
                            color: Color.blue.opacity(0.15),
                            radius: Const.radius,
                            x: 0,
                            y: 4
                        )
                        .draggable(Bundle.main.bundleURL)
                        .onHover { isHovered in
                            if isHovered {
                                NSCursor.openHand.set()
                            } else {
                                NSCursor.arrow.set()
                            }
                        }
                }

                Text(appName)
                    .font(.system(size: 22, weight: .semibold, design: .default))

                Button(action: {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(versionDisplay, forType: .string)
                    copiedVersionFeedback = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                        copiedVersionFeedback = false
                    }
                }) {
                    HStack(spacing: 4) {
                        Text(copiedVersionFeedback ? "已复制版本号" : versionDisplay)
                            .font(.subheadline)
                            .foregroundStyle(copiedVersionFeedback ? Color.accentColor : .secondary)
                        if !copiedVersionFeedback {
                            Image(systemName: "doc.on.doc")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                    }
                }
                .buttonStyle(.plain)
                .help("点击复制完整版本与 Commit 信息")
            }

            Spacer(minLength: 20)

            // 检查更新主交互按钮
            Button(
                action: {
                    checkForUpdates()
                },
                label: {
                    HStack(spacing: 8) {
                        switch updateManager.status {
                        case .checking:
                            ProgressView()
                                .controlSize(.small)
                            Text("正在检查更新...")
                                .font(.system(size: 13, weight: .medium))
                        case .upToDate:
                            Image(systemName: "checkmark.circle.fill")
                                .font(.system(size: 13))
                            Text("已是最新版本 (v\(appVersion))")
                                .font(.system(size: 13, weight: .medium))
                        case .updateAvailable(let version):
                            Image(systemName: "sparkles")
                                .font(.system(size: 13))
                            Text("发现新版本 v\(version)")
                                .font(.system(size: 13, weight: .semibold))
                        case .failed(let msg):
                            Image(systemName: "exclamationmark.triangle.fill")
                                .font(.system(size: 13))
                            Text("检查失败，请检查网络")
                                .font(.system(size: 13, weight: .medium))
                                .help(msg)
                        case .idle:
                            Image(systemName: "arrow.down.circle")
                                .font(.system(size: 13))
                            Text("检查更新")
                                .font(.system(size: 13, weight: .medium))
                        }
                    }
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 7)
                    .background(
                        RoundedRectangle(cornerRadius: Const.radius)
                            .fill(updateManager.status == .upToDate ? Color.green : Color.accentColor)
                    )
                    .foregroundStyle(.white)
                }
            )
            .buttonStyle(.plain)
            .disabled(updateManager.status == .checking)
            .shadow(
                color: Color.accentColor.opacity(0.25),
                radius: Const.radius,
                x: 0,
                y: 3
            )

            // Sparkle 自动更新设置开关
            if let updater = AppDelegate.shared?.updaterController.updater {
                UpdaterSettingsView(updater: updater)
                    .padding(.top, 14)
            }

            Spacer(minLength: 24)

            // 底部链接与许可证声明
            VStack(spacing: 8) {
                HStack(spacing: 24) {
                    if let github = URL(string: "https://github.com/evanoooo/clipboard") {
                        Link(String(localized: .aboutGithub), destination: github)
                    }
                    if let issues = URL(string: "https://github.com/evanoooo/clipboard/issues") {
                        Link(String(localized: .aboutFeedback), destination: issues)
                    }
                }
                .font(.subheadline)

                VStack(spacing: 3) {
                    HStack(spacing: 4) {
                        Text("基于")
                        if let upstream = URL(string: "https://github.com/Ineffable919/clipboard") {
                            Link("Ineffable919/clipboard", destination: upstream)
                                .underline()
                        } else {
                            Text("Ineffable919/clipboard")
                        }
                        Text("进行架构增强 · 遵循 CC BY-NC 4.0 许可")
                    }
                    .font(.caption2)
                    .foregroundStyle(.tertiary)

                    Text(.aboutMadeForMac)
                        .font(.caption2)
                        .foregroundStyle(.secondary)

                    Text(
                        String.localizedStringWithFormat(
                            String(
                                localized: "aboutCopyrightFormat",
                                defaultValue: "Copyright © %lld Crown. All rights reserved.",
                                table: "Localizable"
                            ),
                            currentYear
                        )
                    )
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                }
            }
            .padding(.bottom, 20)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// 检查更新
    private func checkForUpdates() {
        NSApp.activate(ignoringOtherApps: true)
        updateManager.setChecking()
        AppDelegate.shared?.updaterController.checkForUpdates(nil)
    }
}

#Preview {
    AboutSettingView()
        .frame(width: Const.settingWidth - 150, height: Const.settingHeight)
}
