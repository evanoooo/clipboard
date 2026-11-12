//
//  ImageDownsampler.swift
//  Clipboard
//
//  统一的高性能图像下采样工具，防止 4K/5K 大图在卡片渲染、大图预览及 OCR 分析时解压全尺寸位图造成内存暴涨。
//

import AppKit
import CoreGraphics
import Foundation
import ImageIO

nonisolated enum ImageDownsampler {
    /// 针对二进制数据执行只读元数据解析与下采样解码，产出受控分辨率的 CGImage
    static func downsampleCGImage(from data: Data, maxPixelSize: CGFloat) -> CGImage? {
        let options = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, options) else {
            return nil
        }
        let downsampleOptions = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize
        ] as CFDictionary

        return CGImageSourceCreateThumbnailAtIndex(source, 0, downsampleOptions)
            ?? CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    /// 针对二进制数据下采样生成 NSImage
    static func downsampleNSImage(from data: Data, maxPixelSize: CGFloat) -> NSImage? {
        guard let cgImage = downsampleCGImage(from: data, maxPixelSize: maxPixelSize) else {
            return nil
        }
        return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
    }

    /// 针对大图二进制下采样生成轻量 JPEG / PNG 缩略图 Data
    static func generateThumbnailData(
        from data: Data,
        maxPixelSize: CGFloat = 300,
        compressionFactor: Double = 0.8
    ) -> Data? {
        guard let cgImage = downsampleCGImage(from: data, maxPixelSize: maxPixelSize) else {
            return nil
        }
        let rep = NSBitmapImageRep(cgImage: cgImage)
        return rep.representation(using: .jpeg, properties: [.compressionFactor: compressionFactor])
            ?? rep.representation(using: .png, properties: [:])
    }
}
