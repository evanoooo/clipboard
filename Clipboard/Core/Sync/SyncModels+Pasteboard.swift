//
//  SyncModels+Pasteboard.swift
//  Clipboard
//
//  SyncItemBlob 与应用主模型 PasteboardModel 之间的互相转换扩展
//

import AppKit
import Foundation

extension SyncItemBlob {
    init(from model: PasteboardModel) {
        self.init(
            uniqueId: model.uniqueId,
            pasteboardType: model.pasteboardType.rawValue,
            payloadData: model.data,
            showData: model.showData,
            timestamp: model.timestamp,
            group: model.group,
            tag: model.tag,
            alias: model.alias,
            sourceAppName: model.appName
        )
    }

    private var resolvedTextSourceForSearch: String {
        let pType = PasteboardType(rawValue: pasteboardType)
        if pType.isText() || pType == .fileURL,
           let payloadData,
           let str = String(data: payloadData, encoding: .utf8),
           !str.isEmpty {
            return str
        }
        if let showData, !pType.isImage(), let str = String(data: showData, encoding: .utf8) {
            return str
        }
        return ""
    }

    private func resolvedImageMetadata() -> (showData: Data?, length: Int) {
        let isImage = pasteboardType == PasteboardType.png.rawValue
            || pasteboardType == PasteboardType.tiff.rawValue
        guard isImage, let payloadData, !payloadData.isEmpty else {
            return (showData, payloadData?.count ?? 0)
        }
        let resolvedShowData = (showData?.isEmpty == false)
            ? showData
            : ImageDownsampler.generateThumbnailData(from: payloadData, maxPixelSize: 300)
        let packed = PasteboardModel.packImageLength(for: payloadData)
        return (resolvedShowData, packed > 0 ? packed : payloadData.count)
    }

    func toPasteboardModel() -> PasteboardModel {
        let textSource = resolvedTextSourceForSearch
        let imageMeta = resolvedImageMetadata()
        return PasteboardModel(
            pasteboardType: PasteboardType(rawValue: pasteboardType),
            data: payloadData,
            showData: imageMeta.showData,
            timestamp: timestamp,
            appPath: "",
            appName: sourceAppName ?? "",
            searchText: SearchTextNormalizer.normalize(textSource),
            length: imageMeta.length,
            group: group,
            tag: tag,
            alias: alias,
            hidden: false,
            uniqueId: uniqueId,
            appID: nil,
            sourceBundleID: nil
        )
    }

    func toIngestionRecord(appID: Int64) -> SyncIngestionRecord {
        let textSource = resolvedTextSourceForSearch
        let imageMeta = resolvedImageMetadata()
        return SyncIngestionRecord(
            uniqueId: uniqueId,
            type: pasteboardType,
            data: payloadData ?? Data(),
            showData: imageMeta.showData,
            timestamp: timestamp,
            appID: appID,
            searchText: SearchTextNormalizer.normalize(textSource),
            length: imageMeta.length,
            group: group,
            tag: tag,
            hidden: false,
            alias: alias
        )
    }
}
