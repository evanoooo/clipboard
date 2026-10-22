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
                    let d = data ?? PasteDataPointReader.loadData(id: id, uniqueId: uniqueId) ?? Data()
                    if let plain = NSAttributedString(
                        with: d,
                        type: pType
                    )?.string ?? String(data: d, encoding: .utf8) {
                        showData = String(plain.prefix(300)).data(
                            using: .utf8
                        )
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
              model.type != storedType,
              let id = model.id
        else {
            return
        }

        let correctedTag = model.type.tagValue
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
