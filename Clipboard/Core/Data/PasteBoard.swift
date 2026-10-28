//
//  PasteBoard.swift
//  Clipboard
//
//  Created by crown on 2025/9/13.
//

import AppKit
import Combine
import Foundation

@MainActor
final class PasteBoard: PasteboardMonitoringProtocol {
    static let main = PasteBoard()

    private let pasteboard = NSPasteboard.general
    private var changeCount: Int
    /// 自己写入剪贴板后记录的 changeCount。只有当前值仍等于它时才跳过入库，
    /// 避免把写入失败或用户紧接着的复制一起吞掉。
    private var ownWriteChangeCount: Int?

    // MARK: - 自适应能耗感知与静止窗口配置

    private var energyMonitor: SystemEnergyMonitor { SystemEnergyMonitor.shared }
    private var currentEnergyProfile: EnergyProfile { energyMonitor.currentProfile }

    /// Office、浏览器等复制时会分多次写入剪贴板（每次写入都让 changeCount 递增），
    /// 等待静止窗口（Quiescence Window）让写入方收尾，避免入库内容残缺。
    private static let quiescenceDebounce: Duration = .milliseconds(100)

    private var pollTimer: Timer?
    private var currentPollInterval: TimeInterval = 0
    private var idleTicks = 0

    /// 等待中的静止防抖任务
    private var quiescenceTask: Task<Void, Never>?

    // MARK: - 事件辅助加速与系统睡眠观察者

    private var globalKeyMonitor: Any?
    private var localKeyMonitor: Any?
    private var sleepObservers: [NSObjectProtocol] = []

    // MARK: - 暂停功能

    @Published private(set) var isPaused: Bool = false
    private(set) var pausedAt: Date?
    /// 暂停持续时长（秒），nil 表示无限期
    private var pauseDuration: TimeInterval?
    private var resumeTimer: Timer?

    static var sensitiveTypes: Set<String> { PasteboardContentFilter.sensitiveTypes }
    static var ephemeralTypes: Set<String> { PasteboardContentFilter.ephemeralTypes }

    init() {
        changeCount = pasteboard.changeCount
        setupSleepNotifications()
    }

    // MARK: - 监听启停

    func startListening() {
        stopListening()
        guard !isPaused else { return }

        idleTicks = 0
        scheduleNextPoll(interval: currentEnergyProfile.activeInterval)
        registerEventMonitors()
    }

    func stopListening() {
        pollTimer?.invalidate()
        pollTimer = nil
        currentPollInterval = 0
        unregisterEventMonitors()
        quiescenceTask?.cancel()
        quiescenceTask = nil
    }

    // MARK: - 暂停 / 恢复

    /// - Parameter duration: 暂停时长（秒），nil 表示无限期暂停
    func pause(for duration: TimeInterval? = nil) {
        if isPaused {
            resumeTimer?.invalidate()
            resumeTimer = nil
        } else {
            stopListening()
        }

        isPaused = true
        pausedAt = Date()
        pauseDuration = duration

        if let duration {
            let timer = Timer(timeInterval: duration, repeats: false) { [weak self] _ in
                Task { @MainActor in
                    self?.resume()
                }
            }
            RunLoop.main.add(timer, forMode: .common)
            resumeTimer = timer
        }
    }

    func resume() {
        guard isPaused else { return }

        resumeTimer?.invalidate()
        resumeTimer = nil

        isPaused = false
        pausedAt = nil
        pauseDuration = nil
        // 暂停期间复制的内容不应在恢复时补记，否则「暂停」就失去了意义
        changeCount = pasteboard.changeCount
        startListening()
    }

    var pauseEndTime: Date? {
        guard isPaused, let pausedAt, let pauseDuration else {
            return nil
        }
        return pausedAt.addingTimeInterval(pauseDuration)
    }

    /// 是否为无限期暂停
    var isIndefinitePause: Bool {
        isPaused && pauseDuration == nil
    }

    // MARK: - 自适应轮询调度

    private func scheduleNextPoll(interval: TimeInterval) {
        if pollTimer != nil, currentPollInterval == interval {
            return
        }
        pollTimer?.invalidate()
        currentPollInterval = interval
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.performAdaptivePoll()
            }
        }
        timer.tolerance = interval * 0.1
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer
    }

    private func performAdaptivePoll() {
        guard !isPaused else { return }

        let currentCount = pasteboard.changeCount

        if currentCount != changeCount {
            // 检测到变动：重置空闲计数，调度入库并在 120ms 后继续活跃巡检
            idleTicks = 0
            handlePasteboardCountChanged(currentCount: currentCount)
            scheduleNextPoll(interval: currentEnergyProfile.activeInterval)
        } else {
            // 未变动：递增空闲计数，达到阈值后自动拉长间隔到 1.2 秒（节能降频）
            idleTicks += 1
            let nextInterval = idleTicks >= currentEnergyProfile.idleThresholdTicks ? currentEnergyProfile.idleInterval : currentEnergyProfile.activeInterval
            scheduleNextPoll(interval: nextInterval)
        }
    }

    // MARK: - 辅助事件加速（⌘+C / ⌘+X 监视）

    func refreshPermissions() {
        registerEventMonitors()
    }

    private func registerEventMonitors() {
        unregisterEventMonitors()

        // 全局键盘监视（系统其它应用前台按下快捷键时触发）
        globalKeyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.handleKeyEvent(event)
        }

        // 本地键盘监视（本应用窗口活跃时按下快捷键触发）
        localKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.handleKeyEvent(event)
            return event
        }
    }

    private func unregisterEventMonitors() {
        if let globalKeyMonitor {
            NSEvent.removeMonitor(globalKeyMonitor)
            self.globalKeyMonitor = nil
        }
        if let localKeyMonitor {
            NSEvent.removeMonitor(localKeyMonitor)
            self.localKeyMonitor = nil
        }
    }

    private func handleKeyEvent(_ event: NSEvent) {
        guard !isPaused else { return }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard flags.contains(.command) else { return }

        let key = event.charactersIgnoringModifiers?.lowercased()
        if key == "c" || key == "x" || event.keyCode == 8 || event.keyCode == 7 {
            // 捕获到复制/剪切动作：重置空闲计数并在 30ms 后极速主动拉取
            idleTicks = 0
            scheduleNextPoll(interval: 0.03)
        }
    }

    // MARK: - 系统休眠与唤醒

    private func setupSleepNotifications() {
        let wsCenter = NSWorkspace.shared.notificationCenter

        // 系统休眠 / 息屏：挂起轮询定时器
        let sleep1 = wsCenter.addObserver(
            forName: NSWorkspace.willSleepNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.pollTimer?.invalidate()
            self?.pollTimer = nil
            self?.currentPollInterval = 0
        }
        let sleep2 = wsCenter.addObserver(
            forName: NSWorkspace.screensDidSleepNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.pollTimer?.invalidate()
            self?.pollTimer = nil
            self?.currentPollInterval = 0
        }

        // 系统唤醒 / 亮屏：恢复轮询并同步计数值
        let wake1 = wsCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.handleSystemAwake()
        }
        let wake2 = wsCenter.addObserver(
            forName: NSWorkspace.screensDidWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.handleSystemAwake()
        }

        sleepObservers = [sleep1, sleep2, wake1, wake2]

        // 监听系统能耗模式（低电量/发热降频）动态调整
        energyMonitor.onProfileDidChange = { [weak self] profile in
            guard let self, !self.isPaused else { return }
            self.scheduleNextPoll(interval: profile.activeInterval)
        }
    }

    private func handleSystemAwake() {
        guard !isPaused else { return }
        changeCount = pasteboard.changeCount
        idleTicks = 0
        scheduleNextPoll(interval: currentEnergyProfile.activeInterval)
    }

    // MARK: - 剪贴板变更防抖与静止合并

    private func handlePasteboardCountChanged(currentCount: Int) {
        if let owned = ownWriteChangeCount {
            ownWriteChangeCount = nil
            if currentCount == owned {
                changeCount = currentCount
                return
            }
            // 期间又发生了新的外部复制，继续按正常流程入库
        }

        guard currentCount != changeCount else {
            return
        }

        // 调度静止合并窗口：在快速连续写入（如 Office/浏览器写富文本）期间，每次写入重置计时
        scheduleQuiescenceSync(expectedCount: currentCount)
    }

    /// 调度一次静止延迟读取；等待期间再次发现变化会取消并重新计时
    private func scheduleQuiescenceSync(expectedCount: Int) {
        quiescenceTask?.cancel()
        quiescenceTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: Self.quiescenceDebounce)
            guard !Task.isCancelled, let self else { return }
            self.syncPasteboard(expectedCount: expectedCount)
        }
    }

    // MARK: - 读取剪贴板并执行隐私与瞬时过滤

    /// 读取剪贴板并入库
    /// - Parameter expectedCount: 调度时记录的 changeCount。执行时若计数已变，放弃本次读取，等待下一次静止窗口
    private func syncPasteboard(expectedCount: Int) {
        guard pasteboard.changeCount == expectedCount else { return }

        let types = pasteboard.types ?? []

        // 检查隐私设置：忽略机密内容和瞬时内容（优先根据 types 快速过滤，零多余 IO）
        let checkSensitive = PasteUserDefaults.ignoreSensitiveContent
        let checkEphemeral = PasteUserDefaults.ignoreEphemeralContent

        if checkSensitive || checkEphemeral {
            let ignoreResult = shouldIgnoreContent(
                types: types,
                checkSensitive: checkSensitive,
                checkEphemeral: checkEphemeral
            )
            if let reason = ignoreResult {
                Log.pasteboard.info("检测到需忽略的内容，跳过记录: \(reason)")
                // 标记已处理该 changeCount，避免重复触发，同时保证后续正常复制不受阻
                changeCount = pasteboard.changeCount
                return
            }
        }

        let declared = declaredSource()
        let sourceBundleID = resolveSourceBundleID(declared: declared)

        // 机密与安全增强：自动拦截已知密码管理软件与高危敏感凭证（如私钥、Token）
        if checkSensitive {
            if PasteboardContentFilter.isPasswordManager(bundleID: sourceBundleID) {
                log.info("检测到来自密码管理器(\(sourceBundleID ?? ""))的机密内容，跳过记录")
                changeCount = pasteboard.changeCount
                return
            }

            if types.contains(.string),
               let text = pasteboard.string(forType: .string),
               let credentialType = PasteboardContentFilter.detectSensitiveCredential(in: text) {
                Log.pasteboard.info("检测到高危凭证内容(\(credentialType))，跳过记录以保护安全")
                changeCount = pasteboard.changeCount
                return
            }
        }

        // 检查隐私设置：忽略特定应用
        let ignoredApps = PasteUserDefaults.ignoredApps
        if !ignoredApps.isEmpty {
            let isPathValue = declared?.hasPrefix("/") == true
            var sourcePath: String?
            if isPathValue {
                sourcePath = declared
            } else if let declared {
                sourcePath = NSRunningApplication
                    .runningApplications(withBundleIdentifier: declared)
                    .first?.bundleURL?.path
            } else {
                sourcePath = NSWorkspace.shared.frontmostApplication?.bundleURL?.path
            }

            let shouldIgnore = ignoredApps.contains { app in
                if let ignoredID = app.bundleIdentifier,
                   let sourceBundleID,
                   ignoredID == sourceBundleID {
                    return true
                }
                guard let sourcePath else { return false }
                return app.path == sourcePath
            }

            if shouldIgnore {
                log.info(
                    "来自忽略应用的内容，跳过记录: \(sourceBundleID ?? sourcePath ?? "Unknown")"
                )
                changeCount = pasteboard.changeCount
                return
            }
        }

        #if DEBUG
            guard let item = pasteboard.pasteboardItems?.first else { return }
            log.debug("可用类型 \(item.types)")
            for t in item.types {
                if let data = item.data(forType: t), data.count > 4096 {
                    log.debug("  [\(t.rawValue)] data(\(data.count) bytes)")
                } else if let plist = item.propertyList(forType: t) {
                    log.debug("  [\(t.rawValue)] propertyList = \(plist)")
                } else if let str = item.string(forType: t) {
                    let preview =
                        str.prefix(201).count > 200 ? String(str.prefix(200)) + "..." : str
                    log.debug("  [\(t.rawValue)] string = \(preview)")
                } else if let data = item.data(forType: t) {
                    log.debug("  [\(t.rawValue)] data(\(data.count) bytes)")
                }
            }
        #endif

        PasteDataStore.main.addNewItem(pasteboard, sourceApp: resolveSourceApp(declared: declared))
        changeCount = pasteboard.changeCount

        StatusBarController.shared.triggerPulseAnimation()
        SoundManager.shared.play(.copy)
    }

    /// 检查敏感内容和瞬时内容
    func shouldIgnoreContent(
        types: [NSPasteboard.PasteboardType],
        checkSensitive: Bool,
        checkEphemeral: Bool
    ) -> String? {
        PasteboardContentFilter.shouldIgnoreContent(
            types: types,
            checkSensitive: checkSensitive,
            checkEphemeral: checkEphemeral
        )
    }

    private static let sourceType = NSPasteboard.PasteboardType("org.nspasteboard.source")

    /// 解析当前剪贴板写入来源的 Bundle Identifier
    private func resolveSourceBundleID(declared: String? = nil) -> String? {
        let dec = declared ?? declaredSource()
        if let dec {
            if dec.hasPrefix("/") {
                return Bundle(path: dec)?.bundleIdentifier
            }
            return dec
        }
        return NSWorkspace.shared.frontmostApplication?.bundleIdentifier
    }

    /// 剪贴板自带的来源标识：约定是写入方的 bundle id，少数工具会写应用路径
    private func declaredSource() -> String? {
        guard let raw = pasteboard.string(forType: Self.sourceType)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !raw.isEmpty
        else { return nil }
        return raw
    }

    /// 入库归属用：优先按声明的来源找运行中的实例，找不到再回退前台
    private func resolveSourceApp(declared: String? = nil) -> NSRunningApplication? {
        let dec = declared ?? declaredSource()
        if let dec {
            if dec.hasPrefix("/") {
                return NSWorkspace.shared.runningApplications.first {
                    $0.bundleURL?.path == dec
                }
            }
            if let app = NSRunningApplication
                .runningApplications(withBundleIdentifier: dec).first {
                return app
            }
        }
        return NSWorkspace.shared.frontmostApplication
    }

    // MARK: - 写入剪贴板接口

    /// 将多个项目合并写入系统剪贴板
    /// 文本类型会用换行符拼接，文件类型会合并 URL，其他类型只写入第一个
    func pasteMultipleData(
        _ items: [PasteboardModel],
        isAttribute: Bool = true,
        showTip: Bool = false,
        copy: Bool = false
    ) {
        guard !items.isEmpty else { return }

        for item in items {
            item.updateDate()
            if let itemId = item.id {
                PasteDataStore.main.updateDbItem(id: itemId, item: item)
            }
        }

        NSPasteboard.general.clearContents()

        let success = writeMultipleToPasteboard(items, isAttribute: isAttribute)
        guard success else { return }
        // 写入成功后才记录，失败时不留标记，下一次外部复制照常入库
        ownWriteChangeCount = pasteboard.changeCount

        PasteDataStore.main.moveItemsToFirst(items)
        SoundManager.shared.play(.paste)
        if showTip {
            Task { @MainActor in
                copy ? HUDManager.shared.showCopySucceeded() : HUDManager.shared.showPasteSucceeded()
            }
        }
    }

    /// 将多个项目合并写入剪贴板
    private func writeMultipleToPasteboard(
        _ items: [PasteboardModel],
        isAttribute: Bool
    ) -> Bool {
        let shouldPasteAsPlainText =
            !isAttribute || PasteUserDefaults.pasteOnlyText

        let textItems = items.filter { $0.pasteboardType.isText() }
        let fileItems = items.filter { $0.type == .file }
        let imageItems = items.filter { $0.pasteboardType.isImage() }

        // 文件类型
        if !fileItems.isEmpty {
            if !isAttribute {
                let paths = fileItems.flatMap { $0.cachedFilePaths ?? [] }
                guard !paths.isEmpty else { return false }
                NSPasteboard.general.setString(paths.joined(separator: "\n"), forType: .string)
                return true
            }
            return writeMultipleFileURLs(fileItems)
        }

        // 图片类型
        if !imageItems.isEmpty {
            if !isAttribute {
                let text = imageItems.map(\.searchText).filter { !$0.isEmpty }.joined(separator: "\n")
                guard !text.isEmpty else { return false }
                NSPasteboard.general.setString(text, forType: .string)
                return true
            }
            return writeMultipleImages(imageItems)
        }

        // 文本类型合并
        if !textItems.isEmpty {
            if shouldPasteAsPlainText {
                return writeMultiplePlainText(textItems)
            } else {
                return writeMultipleRichText(textItems)
            }
        }

        return false
    }

    /// 合并多个纯文本
    private func writeMultiplePlainText(_ items: [PasteboardModel]) -> Bool {
        let texts = items.compactMap { item -> String? in
            var text = item.plainText
            if PasteUserDefaults.removeTailingNewline {
                text = text.trimmingTrailingNewlines()
            }
            return text.isEmpty ? nil : text
        }
        guard !texts.isEmpty else { return false }

        let combined = texts.joined(separator: "\n")
        NSPasteboard.general.setString(combined, forType: .string)
        return true
    }

    /// 合并多个富文本
    private func writeMultipleRichText(_ items: [PasteboardModel]) -> Bool {
        let combined = NSMutableAttributedString()
        let newline = NSAttributedString(string: "\n")

        for (index, item) in items.enumerated() {
            if let attr = NSAttributedString(
                with: item.data,
                type: item.pasteboardType
            ) {
                let mutable = NSMutableAttributedString(attributedString: attr)
                if PasteUserDefaults.removeTailingNewline {
                    mutable.trimTrailingNewlines()
                }
                combined.append(mutable)
                if index < items.count - 1 {
                    combined.append(newline)
                }
            } else {
                var text = item.plainText
                if PasteUserDefaults.removeTailingNewline {
                    text = text.trimmingTrailingNewlines()
                }
                combined.append(NSAttributedString(string: text))
                if index < items.count - 1 {
                    combined.append(newline)
                }
            }
        }

        guard combined.length > 0 else { return false }

        let rtfType = items.first?.pasteboardType ?? .rtf
        if let data = combined.toData(with: rtfType) {
            NSPasteboard.general.setData(data, forType: rtfType)
        } else {
            NSPasteboard.general.setString(combined.string, forType: .string)
        }
        return true
    }

    /// 合并多个文件 URL
    private func writeMultipleFileURLs(_ items: [PasteboardModel]) -> Bool {
        let fileManager = FileManager.default
        var allURLs: [URL] = []

        for item in items {
            guard let filePaths = String(data: item.data, encoding: .utf8)
            else {
                continue
            }
            let urls =
                filePaths
                    .components(separatedBy: "\n")
                    .lazy
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty && fileManager.fileExists(atPath: $0) }
                    .map { URL(fileURLWithPath: $0) }
            allURLs.append(contentsOf: urls)
        }

        guard !allURLs.isEmpty else { return false }
        pasteboard.writeObjects(allURLs as [NSPasteboardWriting])
        return true
    }

    /// 多张图片写入剪贴板：先写为临时文件，再以文件 URL 方式写入（确保目标应用能接收全部图片）
    private func writeMultipleImages(_ items: [PasteboardModel]) -> Bool {
        let tempDir = FileManager.default.temporaryDirectory
            .appending(path: "ClipboardPaste")

        // 清理旧的临时目录
        try? FileManager.default.removeItem(at: tempDir)
        try? FileManager.default.createDirectory(
            at: tempDir,
            withIntermediateDirectories: true
        )

        var fileURLs: [URL] = []
        for (index, item) in items.enumerated() {
            let ext = item.pasteboardType == .png ? "png" : "tiff"
            let fileName = "image_\(index + 1).\(ext)"
            let fileURL = tempDir.appending(path: fileName)
            do {
                try item.data.write(to: fileURL)
                fileURLs.append(fileURL)
            } catch {
                log.error("写入临时图片文件失败: \(error)")
            }
        }

        guard !fileURLs.isEmpty else { return false }
        pasteboard.writeObjects(fileURLs as [NSPasteboardWriting])

        // 粘贴完成后延迟清理临时文件，给目标应用足够时间读取
        let cleanupDir = tempDir
        Task.detached {
            try? await Task.sleep(for: .seconds(10))
            try? FileManager.default.removeItem(at: cleanupDir)
        }

        return true
    }

    /// 将数据写入系统剪贴板
    /// - Returns: 是否成功写入
    private func writeToPasteboard(_ data: PasteboardModel, isAttribute: Bool)
        -> Bool
    {
        let shouldPasteAsPlainText =
            !isAttribute || PasteUserDefaults.pasteOnlyText

        if data.pasteboardType.isText(), shouldPasteAsPlainText {
            writePlainText(data)
            return true
        }
        if data.type == .file {
            return writeFileURLs(data)
        }
        writeRawData(data)
        return true
    }

    /// 写入纯文本
    private func writePlainText(_ data: PasteboardModel) {
        var text = data.plainText
        if PasteUserDefaults.removeTailingNewline {
            text = text.trimmingTrailingNewlines()
        }
        NSPasteboard.general.setString(text, forType: .string)
    }

    /// 写入文件 URL
    /// - Returns: 是否有有效文件写入
    private func writeFileURLs(_ data: PasteboardModel) -> Bool {
        guard let filePaths = String(data: data.data, encoding: .utf8) else {
            return false
        }

        let fileManager = FileManager.default
        let validURLs =
            filePaths
                .components(separatedBy: "\n")
                .lazy
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty && fileManager.fileExists(atPath: $0) }
                .map { URL(fileURLWithPath: $0) }

        let urlArray = Array(validURLs)
        guard !urlArray.isEmpty else { return false }

        pasteboard.writeObjects(urlArray as [NSPasteboardWriting])
        return true
    }

    /// 写入原始数据（富文本、图片等）
    private func writeRawData(_ data: PasteboardModel) {
        // 处理需要去除末尾换行的富文本
        if data.pasteboardType.isText(),
           PasteUserDefaults.removeTailingNewline,
           let attributedString = NSAttributedString(
               with: data.data,
               type: data.pasteboardType
           )
        {
            let mutableString = NSMutableAttributedString(
                attributedString: attributedString
            )
            mutableString.trimTrailingNewlines()

            if let processedData = mutableString.toData(
                with: data.pasteboardType
            ) {
                NSPasteboard.general.setData(
                    processedData,
                    forType: data.pasteboardType
                )
                return
            }
        }

        NSPasteboard.general.setData(data.data, forType: data.pasteboardType)
    }
}

// MARK: - NSMutableAttributedString Extension

extension NSMutableAttributedString {
    func trimTrailingNewlines() {
        var currentLength = length
        let scalars = string.unicodeScalars
        var index = scalars.endIndex
        while index > scalars.startIndex {
            let prev = scalars.index(before: index)
            let val = scalars[prev].value
            if val == 0x0A || val == 0x0D { // '\n' or '\r'
                index = prev
                currentLength -= 1
            } else {
                break
            }
        }

        if currentLength < length {
            deleteCharacters(
                in: NSRange(
                    location: currentLength,
                    length: length - currentLength
                )
            )
        }
    }
}
