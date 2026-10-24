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

    func toPasteboardModel() -> PasteboardModel {
        let textSource: String = if let payloadData, let str = String(data: payloadData, encoding: .utf8), !str.isEmpty {
            str
        } else if let showData, let str = String(data: showData, encoding: .utf8) {
            str
        } else {
            ""
        }
        return PasteboardModel(
            pasteboardType: PasteboardType(rawValue: pasteboardType) ?? .string,
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
}
