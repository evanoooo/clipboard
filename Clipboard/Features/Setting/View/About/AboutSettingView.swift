//
//  AboutSettingView.swift
//  Clipboard
//
//  Created by crown on 2025/11/11.
//

import SwiftUI

struct AboutSettingView: View {
    private var appName: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String
            ?? "Clipboard"
    }

    private var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString")
            as? String ?? "1.0"
    }

    private var buildNumber: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
            ?? "1"
    }

    private let currentYear = Calendar.current.component(.year, from: Date())

    var body: some View {
        ScrollView(.vertical) {
            VStack(spacing: 8) {
                if let appIcon = NSImage(named: "AppIcon") {
                    Image(nsImage: appIcon)
                        .resizable()
                        .frame(width: 96, height: 96)
                        .shadow(
                            color: Color.blue.opacity(0.15),
                            radius: Const.radius,
                            x: 0,
                            y: 6
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
                    .font(
                        .system(size: 24, weight: .medium, design: .default)
                    )

                Text("\(appVersion) (\(buildNumber))")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .padding(.top, Const.space16)
            .frame(maxWidth: .infinity)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: Const.space12) {
                HStack(spacing: 20) {
                    if let github = URL(string: "https://github.com/Ineffable919/clipboard") {
                        Link(String(localized: .aboutGithub), destination: github)
                    }
                    if let issues = URL(string: "https://github.com/Ineffable919/clipboard/issues") {
                        Link(String(localized: .aboutFeedback), destination: issues)
                    }
                }
                VStack(spacing: Const.space4) {
                    Text(.aboutMadeForMac)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(
                        String.localizedStringWithFormat(
                            String(
                                localized: "aboutCopyrightFormat",
                                defaultValue: "Copyright © %lld Crown. All rights reserved.",
                                table: "Localizable"
                            ),
                            currentYear
                        ),
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                .padding(.bottom, Const.space16)
            }
            .frame(maxWidth: .infinity)
        }
        .scrollIndicators(.hidden)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

#Preview {
    AboutSettingView()
        .frame(width: Const.settingWidth - 150, height: Const.settingHeight)
}
