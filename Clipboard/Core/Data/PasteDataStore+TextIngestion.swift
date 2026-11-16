import AppKit

extension PasteDataStore {
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
                let prefix = data.prefix(1024)
                let uniqueId = "\(prefix.sha256Hex)-\(data.count)"
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
}
