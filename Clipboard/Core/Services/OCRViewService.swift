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

    nonisolated private static func createCGImage(from data: Data) -> CGImage? {
        let options = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, options) else {
            return nil
        }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    func recognizeText(from data: Data) async -> String {
        await Task.detached(priority: .utility) {
            autoreleasepool {
                guard let cgImage = Self.createCGImage(from: data) else { return "" }

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
