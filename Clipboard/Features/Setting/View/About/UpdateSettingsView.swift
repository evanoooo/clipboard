//
//  UpdateSettingsView.swift
//  Clipboard
//
//  Created by crown on 2025/11/19.
//

import Sparkle
import SwiftUI

struct UpdaterSettingsView: View {
    private let updater: SPUUpdater

    @State private var automaticallyChecksForUpdates: Bool
    @State private var automaticallyDownloadsUpdates: Bool

    init(updater: SPUUpdater) {
        self.updater = updater
        automaticallyChecksForUpdates = updater.automaticallyChecksForUpdates
        automaticallyDownloadsUpdates = updater.automaticallyDownloadsUpdates
    }

    var body: some View {
        HStack(spacing: Const.space12) {
            settingsToggle(
                title: "自动检查更新",
                isOn: $automaticallyChecksForUpdates
            )
            .onChange(of: automaticallyChecksForUpdates) { _, newValue in
                updater.automaticallyChecksForUpdates = newValue
            }

            settingsToggle(
                title: "自动下载更新",
                isOn: $automaticallyDownloadsUpdates
            )
            .disabled(!automaticallyChecksForUpdates)
            .onChange(of: automaticallyDownloadsUpdates) { _, newValue in
                updater.automaticallyDownloadsUpdates = newValue
            }
        }
        .padding(.horizontal, Const.space16)
        .padding(.top, Const.space16)
        .padding(.bottom, Const.space4)
        .frame(maxWidth: .infinity, alignment: .center)
    }

    private func settingsToggle(title: String, isOn: Binding<Bool>) -> some View {
        Toggle(isOn: isOn) {
            Text(title)
                .lineLimit(1)
                .truncationMode(.tail)
                .help(title)
        }
        .help(title)
    }
}
