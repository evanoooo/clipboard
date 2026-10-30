import AppKit
import SQLite

// MARK: - Row → Model 映射

extension PasteDataStore {
    func getItems(limit: Int = 50, offset: Int? = nil) async
        -> [PasteboardModel] {
        let rows = await PasteReadStore.shared.search(
            filter: Col.hidden == 0,
            limit: limit,
            offset: offset
        )
        return await mapRows(rows)
    }

    func mapRows(_ rows: [Row]) async -> [PasteboardModel] {
        await loadMissingApps(in: rows)
        return rows.compactMap { row in
            if let type = try? row.get(Col.type),
               let timestamp = try? row.get(Col.timestamp),
               let uniqueId = try? row.get(Col.uniqueId) {
                let data = try? row.get(Col.data)
                let id = try? row.get(Col.id)
                let appID = try? row.get(Col.appID)
                var showData = try? row.get(Col.showData)
                let searchText = try? row.get(Col.searchText)
                let length = try? row.get(Col.length)
                let group = try? row.get(Col.group)
                let tag = try? row.get(Col.tag)
                let alias = try? row.get(Col.alias)
                let sortOrder = (try? row.get(Col.sortOrder)) ?? 0
                let hidden = ((try? row.get(Col.hidden)) ?? 0) != 0

                let pType = PasteboardType(type)

                if pType.isText(), showData == nil {
                    // 极致性能：优先从已在行记录中的 searchText 提取兜底预览，杜绝在映射流水线中发起同步磁盘 I/O
                    if let searchText, !searchText.isEmpty {
                        showData = String(searchText.prefix(300)).data(using: .utf8)
                    } else if let d = data {
                        let plain = NSAttributedString(with: d, type: pType)?.string ?? String(data: d, encoding: .utf8)
                        showData = plain.flatMap { String($0.prefix(300)).data(using: .utf8) }
                    }
                }

                let pasteModel = PasteboardModel(
                    pasteboardType: pType,
                    data: data,
                    showData: showData,
                    timestamp: timestamp,
                    appPath: "",
                    appName: "",
                    searchText: searchText ?? "",
                    length: length ?? 0,
                    group: group ?? -1,
                    tag: tag ?? "",
                    alias: alias ?? "",
                    hidden: hidden,
                    uniqueId: uniqueId,
                    appID: appID
                )
                pasteModel.id = id
                pasteModel.sortOrder = sortOrder
                // 性能极致优化：移除映射主流程上的代码语言嗅探，由卡片展示时按需懒加载并缓存，杜绝阻塞列表加载
                repairTagIfNeeded(pasteModel)
                return pasteModel
            }
            return nil
        }
    }

    private func loadMissingApps(in rows: [Row]) async {
        let missingIDs = Set(rows.compactMap { try? $0.get(Col.appID) })
            .filter { SourceAppCache.shared.apps[$0] == nil }
        if !missingIDs.isEmpty {
            _ = try? await sqlManager.sourceApps(ids: missingIDs)
            await sqlManager.refreshAppCache()
        }
    }

    private func repairTagIfNeeded(_ model: PasteboardModel) {
        guard let storedType = PasteModelType(rawValue: model.tag),
              storedType == .link || storedType == .color,
              let id = model.id
        else {
            return
        }

        let isStillValid = (storedType == .link && model.isLink) || (storedType == .color && model.isCSS)
        guard !isStillValid else { return }

        let correctedTag = (model.pasteboardType == .string ? PasteModelType.string : PasteModelType.rich).tagValue
        guard !correctedTag.isEmpty,
              repairingTagIds.insert(id).inserted
        else {
            return
        }

        Task { [weak self] in
            guard let self else { return }

            _ = await sqlManager.updateItemTag(
                id: id,
                expectedTag: storedType.tagValue,
                newTag: correctedTag
            )
            repairingTagIds.remove(id)
        }
    }
}
