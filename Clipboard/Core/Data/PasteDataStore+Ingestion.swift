//
//  PasteDataStore+Ingestion.swift
//  Clipboard
//
//  系统剪贴板监听入库、后台文本/富文本/图片异步解析以及云端同步批量录入管线
//

import AppKit
import Combine
import Foundation
import SQLite

extension PasteDataStore {
    @discardableResult
    func addNewItem(
        _ item: NSPasteboard,
        sourceApp: NSRunningApplication? = nil,
        chipId: Int = -1,
        preloadedStringData: Data? = nil
    ) -> Bool {
        var preloadedFilePaths: [String]?
        if let first = item.pasteboardItems?.first {
            let extractedPaths = PasteboardModel.extractFilePaths(from: item, item: first)
            preloadedFilePaths = extractedPaths ?? []
            if extractedPaths == nil,
               let matchedType = first.availableType(from: PasteboardType.supportTypes) {
                if matchedType == .string {
                    let data = preloadedStringData ?? first.data(forType: .string)
                    if let data, data.count > 16_384 {
                        ingestionTask = ingestText(data, sourceApp: sourceApp, chipId: chipId, after: ingestionTask)
                        return true
                    }
                } else if matchedType == .rtf || matchedType == .rtfd {
                    if let richData = first.data(forType: matchedType), !richData.isEmpty {
                        ingestionTask = ingestRichText(
                            richData,
                            type: matchedType,
                            sourceApp: sourceApp,
                            chipId: chipId,
                            after: ingestionTask
                        )
                        return true
                    }
                } else if matchedType.isImage(), let imageData = first.data(forType: matchedType), !imageData.isEmpty {
                    ingestionTask = ingestImage(
                        imageData,
                        type: matchedType,
                        sourceApp: sourceApp,
                        chipId: chipId,
                        after: ingestionTask
                    )
                    return true
                }
            }
        }
        guard let model = PasteboardModel(
            with: item,
            sourceApp: sourceApp,
            preloadedData: preloadedStringData,
            preloadedFilePaths: preloadedFilePaths
        ) else { return false }

        if chipId != -1 {
            model.updateGroup(val: chipId)
        }

        let previous = ingestionTask
        ingestionTask = Task {
            await previous?.value
            await insertModel(model)
            SyncEngine.shared.markDirtyAndSchedule()
            // 极致轻量：入库完成后立即释放原始大图，避免大 BLOB 常驻内存
            await MainActor.run {
                model.evictRawData()
                if model.type == .image, let id = model.id {
                    DeferredOCRCoordinator.shared.enqueue(id: id)
                }
            }
        }
        return true
    }

    func ingestText(
        _ data: Data,
        sourceApp: NSRunningApplication?,
        chipId: Int,
        after previous: Task<Void, Never>?
    ) -> Task<Void, Never> {
        let app = sourceApp ?? NSWorkspace.shared.frontmostApplication
        let appPath = app?.bundleURL?.path ?? ""
        let appName = app?.localizedName ?? ""
        let bundleID = app?.bundleIdentifier
        let timestamp = Int64(Date().timeIntervalSince1970)
        return Task {
            await previous?.value
            guard let content = await Task.detached(priority: .utility, operation: {
                PasteboardTextPreparation.prepare(data)
            }).value else { return }
            let model = PasteboardModel(
                pasteboardType: .string,
                data: data,
                showData: content.showData,
                timestamp: timestamp,
                appPath: appPath,
                appName: appName,
                searchText: content.searchText,
                length: content.length,
                group: chipId,
                tag: content.tag,
                uniqueId: content.uniqueId,
                sourceBundleID: bundleID
            )
            await insertModel(model)
            SyncEngine.shared.markDirtyAndSchedule()
            await MainActor.run {
                model.evictRawData()
            }
        }
    }

    func ingestRichText(
        _ data: Data,
        type: PasteboardType,
        sourceApp: NSRunningApplication?,
        chipId: Int,
        after previous: Task<Void, Never>?
    ) -> Task<Void, Never> {
        struct PreparedRichText: Sendable {
            let showData: Data
            let searchText: String
            let length: Int
            let tag: String
            let uniqueId: String
        }

        let app = sourceApp ?? NSWorkspace.shared.frontmostApplication
        let appPath = app?.bundleURL?.path ?? ""
        let appName = app?.localizedName ?? ""
        let bundleID = app?.bundleIdentifier
        let timestamp = Int64(Date().timeIntervalSince1970)

        return Task {
            await previous?.value
            guard let prepared = await Task.detached(priority: .utility, operation: { () -> PreparedRichText? in
                guard let parsed = PasteboardModel.prepareText(data, type: type) else {
                    return nil
                }
                let rawString = parsed.source.string
                let length = parsed.source.length
                let searchText = PasteboardModel.normalizeSearchText(rawString)
                let tag = PasteboardModel.calculateTag(type: type, content: data, extractedText: rawString)
                let uniqueId = PasteboardModel.generateUniqueId(for: type, data: data)
                return PreparedRichText(
                    showData: parsed.showData ?? Data(),
                    searchText: searchText,
                    length: length,
                    tag: tag,
                    uniqueId: uniqueId
                )
            }).value else { return }

            let model = PasteboardModel(
                pasteboardType: type,
                data: data,
                showData: prepared.showData,
                timestamp: timestamp,
                appPath: appPath,
                appName: appName,
                searchText: prepared.searchText,
                length: prepared.length,
                group: chipId,
                tag: prepared.tag,
                uniqueId: prepared.uniqueId,
                sourceBundleID: bundleID
            )
            await insertModel(model)
            SyncEngine.shared.markDirtyAndSchedule()
            await MainActor.run {
                model.evictRawData()
            }
        }
    }

    func ingestImage(
        _ data: Data,
        type: PasteboardType,
        sourceApp: NSRunningApplication?,
        chipId: Int,
        after previous: Task<Void, Never>?
    ) -> Task<Void, Never> {
        let app = sourceApp ?? NSWorkspace.shared.frontmostApplication
        let appPath = app?.bundleURL?.path ?? ""
        let appName = app?.localizedName ?? ""
        let bundleID = app?.bundleIdentifier
        let timestamp = Int64(Date().timeIntervalSince1970)
        return Task {
            await previous?.value
            let prepared = await Task.detached(priority: .utility) { () -> (showData: Data, length: Int, uniqueId: String) in
                let showData = ImageDownsampler.generateThumbnailData(from: data, maxPixelSize: 300) ?? Data()
                var length = 0
                if let size = PasteboardModel.computeImageSize(from: data) {
                    let w = Int(size.width)
                    let h = Int(size.height)
                    if w > 0 && h > 0 {
                        length = (w << 32) | (h & 0xFFFF_FFFF)
                    }
                }
                let uniqueId = PasteboardModel.generateUniqueId(for: type, data: data)
                return (showData, length, uniqueId)
            }.value

            let model = PasteboardModel(
                pasteboardType: type,
                data: data,
                showData: prepared.showData,
                timestamp: timestamp,
                appPath: appPath,
                appName: appName,
                searchText: "",
                length: prepared.length,
                group: chipId,
                tag: "image",
                uniqueId: prepared.uniqueId,
                sourceBundleID: bundleID
            )
            await insertModel(model)
            SyncEngine.shared.markDirtyAndSchedule()
            await MainActor.run {
                model.evictRawData()
                if let id = model.id {
                    DeferredOCRCoordinator.shared.enqueue(id: id)
                }
            }
        }
    }

    private func prepareApp(for model: PasteboardModel) async -> Bool {
        do {
            let id: Int64
            if let existing = model.appID {
                id = existing
            } else {
                id = try await sqlManager.resolveApp(
                    name: model.appName, path: model.appPath, bundleID: model.sourceBundleID
                )
            }
            model.appID = id
            return true
        } catch {
            log.error("保存来源应用失败：\(error)")
            return false
        }
    }

    /// 静默录入由云端同步拉取的条目（仅底层 SQLite 持久化并解析 App，不劫持当前内存剪贴板列表顶部，不触发即时动画）
    func ingestSyncedModel(_ model: PasteboardModel) async {
        guard await prepareApp(for: model) else { return }
        let result = await sqlManager.insert(
            item: model,
            timestamp: model.timestamp,
            group: model.group
        )
        guard result.id >= 0 else { return }
        model.id = result.id
        model.appID = result.appID
        model.sortOrder = result.sortOrder
        await MainActor.run {
            model.evictRawData()
        }
    }

    /// 批量静默录入由云端同步下载的纯净 Blob（后台直通入库，彻底免除主线程调度与中间模型对象开销）
    func ingestSyncedBlobs(_ blobs: [SyncItemBlob]) async {
        guard !blobs.isEmpty else { return }
        var records: [SyncIngestionRecord] = []
        for blob in blobs {
            let appID: Int64
            do {
                appID = try await sqlManager.resolveApp(
                    name: blob.sourceAppName ?? "",
                    path: "",
                    bundleID: nil
                )
            } catch {
                appID = 1
            }
            records.append(blob.toIngestionRecord(appID: appID))
        }
        await sqlManager.ingestSyncedBatch(records)
    }

    /// 批量静默录入由云端同步拉取的条目（单事务提交，解决海量数据恢复时逐条写入的 I/O 阻塞）
    func ingestSyncedBatch(_ models: [PasteboardModel]) async {
        guard !models.isEmpty else { return }
        var records: [SyncIngestionRecord] = []
        for model in models {
            _ = await prepareApp(for: model)
            records.append(SyncIngestionRecord(
                uniqueId: model.uniqueId,
                type: model.pasteboardType.rawValue,
                data: model.data,
                showData: model.showData,
                timestamp: model.timestamp,
                appID: model.appID ?? 1,
                searchText: model.searchText,
                length: model.length,
                group: model.group,
                tag: model.tag,
                hidden: model.hidden,
                alias: model.alias
            ))
        }
        await sqlManager.ingestSyncedBatch(records)
        await MainActor.run {
            for model in models {
                model.evictRawData()
            }
        }
    }

    /// 批量静默删除远端已标记墓碑的本地条目（单事务执行，不抢占前台 UI）
    func deleteSyncedBatch(uniqueIds: [String]) async {
        guard !uniqueIds.isEmpty else { return }
        await sqlManager.deleteByUniqueIds(uniqueIds)
    }

    func insertModel(_ model: PasteboardModel) async {
        guard await prepareApp(for: model) else { return }
        let result = await sqlManager.insert(
            item: model,
            timestamp: model.timestamp,
            group: model.group
        )
        guard result.id >= 0 else { return }
        model.appID = result.appID
        let insertedAppID = result.appID
        await MainActor.run { SourceAppCache.shared.promote(appID: insertedAppID) }
        AppColorService.shared.updateColor(for: model)
        if result.didIncreaseTotalCount {
            totalCount += 1
        }
        let count = totalCount

        model.id = result.id
        model.sortOrder = result.sortOrder
        if let group = result.group {
            model.updateGroup(val: group)
        }
        totalCount = count

        if isInFilterMode, let filter = currentFilter {
            if !isFilteredCountCapped {
                let scanned = await PasteReadStore.shared.getCount(filter: filter, limit: Self.countScanLimit)
                updateFilteredCount(scanned: scanned)
            } else {
                countUpdated.send()
            }
            guard let id = model.id,
                  await modelMatchesActiveFilter(model, filter: filter, modelId: id)
            else { return }
        } else {
            filterState.filteredCount = count
            filterState.isCountCapped = false
            countUpdated.send()
        }

        var list = dataList.value
        list.removeAll(where: { $0.uniqueId == model.uniqueId })
        list.insert(model, at: 0)
        let truncated = Array(list.prefix(pageSize))
        hasMoreData = isInFilterMode ? (isFilteredCountCapped || filteredCount > truncated.count) : (totalCount > truncated.count)

        pageIndex = 0
        lastRequestedPage = 0
        loadPageTask?.cancel()
        isLoadingPage = false

        updateData(with: truncated, changeType: .new)
    }
}
