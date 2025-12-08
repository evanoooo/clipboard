//
//  View+Extension.swift
//  Clipboard
//
//  Created by crown on 2025/12/06.
//

import SwiftUI

// MARK: - Settings Style Modifier

struct SettingsStyleModifier: ViewModifier {
    @Environment(\.colorScheme) var colorScheme

    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: Const.settingsRadius)
                    .fill(
                        colorScheme == .light
                            ? Const.lightBackground : Const.darkBackground
                    )
            )
            .overlay(
                RoundedRectangle(cornerRadius: Const.settingsRadius)
                    .stroke(Color.gray.opacity(0.2), lineWidth: 1)
            )
    }
}

struct TextCardStyleModifier: ViewModifier {
    func body(content: Content) -> some View {
        content
            .textSelection(.disabled)
            .padding(
                .init(
                    top: Const.space8,
                    leading: Const.space10,
                    bottom: 0.0,
                    trailing: Const.space8
                )
            )
            .frame(
                maxWidth: .infinity,
                maxHeight: .infinity,
                alignment: .topLeading,
            )
    }
}

extension View {
    func settingsStyle() -> some View {
        modifier(SettingsStyleModifier())
    }

    func textCardStyle() -> some View {
        modifier(TextCardStyleModifier())
    }
}
