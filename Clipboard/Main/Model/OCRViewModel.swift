//
//  OCRViewModel.swift
//  Clipboard
//
//  Created by crown on 2026/01/01.
//

import AppKit
import Vision

@MainActor
@Observable
class OCRViewModel {
    var recognizedText: String = ""
    var isProcessing: Bool = false

    func recognizeText(from image: NSImage) async {
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return }

        isProcessing = true
        defer { isProcessing = false }

        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate // .fast 更快但精度稍低
        request.recognitionLanguages = ["zh-Hans", "zh-Hant", "en-US"]
        request.usesLanguageCorrection = true

        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])

        do {
            try handler.perform([request])
            recognizedText = (request.results ?? [])
                .compactMap { $0.topCandidates(1).first?.string }
                .joined(separator: "\n")
        } catch {
            print("OCR 失败: \(error.localizedDescription)")
        }
    }
}
