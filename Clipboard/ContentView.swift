//
//  ContentView.swift
//  clipboard
//
//  Created by crown on 2025/9/11.
//

import SwiftUI

// MARK: - ContentView

struct ContentView: View {
    @FocusState private var focused: Bool
    @State private var pd = PasteDataStore.main

    @ViewBuilder
    private func contentStack() -> some View {
        VStack {
            Spacer()
            ClipTopBarView()
            HistoryAreaView(pd: pd)
                .focusable()
                .focusEffectDisabled()
                .focused($focused)
        }
    }

    var body: some View {
        Group {
            if #available(macOS 26.0, *) {
                ZStack {
                    RoundedRectangle(cornerRadius: Const.radius)
                        .fill(Color.clear)
                        .glassEffect(
                            in: RoundedRectangle(cornerRadius: Const.radius)
                        )
                    contentStack()
                }
            } else {
                contentStack()
                    .padding(.bottom, Const.cardBottomPadding)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task {
            if Task.isCancelled { return }
            await MainActor.run {
                focused = true
            }
        }
    }
}

// MARK: - Preview

#Preview {
    ContentView()
        .frame(width: 1000, height: 330.0)
}
