//
//  OCRView.swift
//  Clipboard
//
//  Created by crown on 2026/1/1.
//

import SwiftUI
import UniformTypeIdentifiers

struct OCRView: View {
    @State private var viewModel = OCRViewModel()
    @State private var droppedImage: NSImage?

    var body: some View {
        VStack(spacing: 16) {
            ZStack {
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(style: StrokeStyle(lineWidth: 2, dash: [8]))
                    .foregroundStyle(.secondary)

                if let image = droppedImage {
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFit()
                } else {
                    Text("拖拽图片到此处")
                        .foregroundStyle(.secondary)
                }
            }
            .frame(height: 200)
            .onDrop(of: [.image], isTargeted: nil) { providers in
                handleDrop(providers)
            }

            if viewModel.isProcessing {
                ProgressView("识别中...")
            } else {
                TextEditor(text: .constant(viewModel.recognizedText))
                    .frame(minHeight: 100)
            }
        }
        .padding()
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first else { return false }
        provider.loadObject(ofClass: NSImage.self) { image, _ in
            guard let nsImage = image as? NSImage else { return }
            Task { @MainActor in
                droppedImage = nsImage
                await viewModel.recognizeText(from: nsImage)
            }
        }
        return true
    }
}
