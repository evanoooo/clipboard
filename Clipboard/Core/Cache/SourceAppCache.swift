import Combine
import Foundation

@MainActor
final class SourceAppCache {
    static let shared = SourceAppCache()
    private(set) var apps: [Int64: SourceApp] = [:]
    private var orderedIDs: [Int64] = []
    let changes = PassthroughSubject<Void, Never>()

    private var _cachedOrderedApps: [SourceApp]?

    var orderedApps: [SourceApp] {
        if let cached = _cachedOrderedApps { return cached }
        let result = orderedIDs.compactMap { apps[$0] }.filter { !$0.name.isEmpty }
        _cachedOrderedApps = result
        return result
    }
    private var warmingTask: Task<Void, Never>?

    func replace(_ records: [SourceApp]) {
        warmingTask?.cancel()
        apps = Dictionary(uniqueKeysWithValues: records.map { ($0.id, $0) })
        orderedIDs = records.map(\.id)
        _cachedOrderedApps = nil
        AppIconCache.shared.clearCache()
        changes.send()
    }

    /// SQL 写入完成后发布有历史引用的应用；不清理磁盘 App 表、不重建图标缓存。
    func synchronize(_ records: [SourceApp]) {
        let ids = records.map(\.id)
        let updated = Dictionary(uniqueKeysWithValues: records.map { ($0.id, $0) })
        guard orderedIDs != ids || apps != updated else { return }
        if records.contains(where: { app in
            apps[app.id].map { $0.path != app.path } ?? false
        }) {
            AppIconCache.shared.clearCache()
        }
        orderedIDs = ids
        apps = updated
        _cachedOrderedApps = nil
        changes.send()
    }

    /// 增量提升应用排序：将该应用置于有序列表首位（纯内存极速操作，杜绝全表 GROUP BY 聚合扫描）
    func promote(appID: Int64?) {
        guard let appID else { return }
        guard let index = orderedIDs.firstIndex(of: appID) else {
            if apps[appID] != nil {
                orderedIDs.insert(appID, at: 0)
                _cachedOrderedApps = nil
                changes.send()
            }
            return
        }
        if index > 0 {
            orderedIDs.remove(at: index)
            orderedIDs.insert(appID, at: 0)
            _cachedOrderedApps = nil
            changes.send()
        }
    }

    func update(_ app: SourceApp) {
        guard apps[app.id] != app else { return }
        if let previous = apps[app.id], previous.path != app.path { AppIconCache.shared.clearCache() }
        guard apps[app.id] != nil else { return }
        apps[app.id] = app
        _cachedOrderedApps = nil
    }

    func warmMissingIcons() {
        warmingTask?.cancel()
        // 仅预热最近活跃的 Top 15 个应用图标，其余历史冷门应用在卡片滑入时按需加载，避免启动时并发占用内存
        let topApps = Array(orderedApps.prefix(15))
        warmingTask = Task(priority: .utility) {
            for app in topApps {
                guard !Task.isCancelled else { return }
                _ = await AppIconCache.shared.loadIcon(forAppID: app.id, path: app.path)
                await Task.yield()
            }
        }
    }
}
