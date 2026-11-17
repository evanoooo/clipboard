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

    func toPasteboardModel() -> PasteboardModel {
        let textSource = resolvedTextSourceForSearch
        return PasteboardModel(
            pasteboardType: PasteboardType(rawValue: pasteboardType),
            data: payloadData,
            showData: showData,
            timestamp: timestamp,
            appPath: "",
            appName: sourceAppName ?? "",
            searchText: SearchTextNormalizer.normalize(textSource),
            length: payloadData?.count ?? 0,
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
        return SyncIngestionRecord(
            uniqueId: uniqueId,
            type: pasteboardType,
            data: payloadData ?? Data(),
            showData: showData,
            timestamp: timestamp,
            appID: appID,
            searchText: SearchTextNormalizer.normalize(textSource),
            length: payloadData?.count ?? 0,
            group: group,
            tag: tag,
            hidden: false,
            alias: alias
        )
    }
}
