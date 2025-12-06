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

extension View {
    func settingsStyle() -> some View {
        modifier(SettingsStyleModifier())
    }
}
