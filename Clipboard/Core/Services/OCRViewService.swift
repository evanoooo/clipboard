//
//  OCRViewService.swift
//  Clipboard
//
//  Created by crown on 2026/01/01.
//

import AppKit
import Vision

final class OCRViewService {
    static let shared = OCRViewService()

    private init() {}

    func recognizeText(from data: Data) async -> String {
        await Task.detached(priority: .utility) {
            autoreleasepool {
                // OCR 下采样至 3000px，保留高精度文字识别细节的同时将 5K 位图面积收敛至 1/3~1/4，杜绝单次 OCR 占用 150MB+ 内存尖峰
                guard let cgImage = ImageDownsampler.downsampleCGImage(from: data, maxPixelSize: 3000) else { return "" }

                let request = VNRecognizeTextRequest()
                request.recognitionLevel = .accurate
                request.recognitionLanguages = ["zh-Hans", "zh-Hant", "en-US"]
                request.usesLanguageCorrection = true

                let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])

                do {
                    try handler.perform([request])
                    return (request.results ?? [])
                        .compactMap { $0.topCandidates(1).first?.string }
                        .joined(separator: "\n")
                } catch {
                    return ""
                }
            }
        }.value
    }
}
