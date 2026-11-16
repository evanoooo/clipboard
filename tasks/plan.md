# Clipboard 内存、性能与架构优化规划

> 更新日期：2026-11-16
> 当前本地验证版本：`2.4.7 (954)`（`NativeToolbox Dev` 签名，650/650 单元测试通过）

---

## 一、实测基线与阶段成果

| 指标 | 优化前（基线） | 阶段 A 后（实测） | 核心改善来源 |
| :--- | :--- | :--- | :--- |
| 空闲 `phys_footprint` | `208 MB`（活动监视器 `371.3 MB`） | **`18 MB`** | 延迟冷启动后台 OCR（避免 Vision/Espresso 常驻 `62 MB` + Malloc 碎片） |
| 峰值 `phys_footprint_peak` | `476 MB`（活动监视器 `517.5 MB`） | **`26 MB`** | 禁用大图全尺寸解码 OOM 回退 + `malloc_zone_pressure_relief` |
| 首次启动设置白屏 | 设置/编辑/欢迎窗偶现白屏 | **已修复** | `isRestorable = false` + `layoutIfNeeded()` 强制布局 |
| 单元测试 | — | **650 / 650 通过** | — |

---

## 二、Phase A：已完成并验证的优化与修复（Batch 1–4）

### A1. 内存占用与 OOM 治理
- **图片解码防 OOM 回退**（`Clipboard/Core/Utils/ImageDownsampler.swift`）：`CGImageSourceCreateImageAtIndex` 前检查像素尺寸，拒绝超大原图全尺寸解码。
- **RTFD/RTF 列表预览瘦身**（`Clipboard/Core/Models/Pasteboard/PasteboardModel+Pasteboard.swift`、`NSAttributeString+Extension.swift`）：`showData` 剥离 `NSTextAttachment` 并截断至 16KB；预计算 RTF/RTFD `uniqueId` 并缓存 `extractedPaths`。
- **NSCache 成本校准与内存修剪**（`PasteboardModelCaches.swift`、`AppIconCache.swift`、`PasteboardModel+RuntimeCache.swift`、`PasteDataStore.swift`）：按像素/属性校准成本，修复 `trimMemory()` 任务取消/代际竞争，`setup()` 后主动触发 `malloc_zone_pressure_relief`。
- **OCR 并发与冷启动控制**（`OCRViewService.swift`、`DeferredOCRCoordinator.swift`）：限制 OCR 最大并发为 2，支持优先级传播，冷启动延迟后台 OCR 并释放堆碎片。
- **MCP & 迁移缓冲限制**（`MCPTools.swift`、`PasteMigrationService.swift`）：MCP 图片降采样至 `<=1024px` JPEG、文本截断 `20,000` 字符；限制 LZFSE 解压缓冲并刷新 `totalCount`。

### A2. 泄漏与 UI/交互修复
- 修复全局 `NSEvent` 监听泄漏（`ShortcutRecorderView.swift`）。
- 窗口关闭清理 `undoManager` / `firstResponder` / `viewport.cancelWork()`，改用 `editedRange` 增量处理（`EditWindowController.swift`、`JSONEditorView.swift`）。
- 修复 `StorageInspectorSheet` 异步任务取消（`withTaskCancellationHandler`）。
- 修复 `HUDManager` 淡出竞态、`NSColor+Extension` / `Color+Extension` 3/4/8 位十六进制解析，以及 `isRestorable = false` 导致的首次启动白屏。

### A3. 查询、同步与热路径优化
- **SQLite 索引与混合检索**（`PasteSQLManager.swift`、`PasteFilterBuilder.swift`）：新增 `idx_hidden_ts_app` 与 `idx_unpinned_ts`，混合 FTS5 + LIKE 查询。
- **后台预处理与高亮/遮罩加速**（`PasteDataStore+TextIngestion.swift`、`JSONSyntaxHighlighter.swift`、`JSONViewportEditor+Layout.swift`、`ContentMaskCalculator.swift`、`String+Extension.swift`）：`calculateTag` 移至后台 `Task.detached`；跳过无用 `.key`/`.punctuation` span；复用 TextKit 测量栈并安全按字符簇截断；缓存 `NSDataDetector`。
- **链接元数据与颜色提取**（`LinkMetadataService.swift`、`AppColorService.swift`、`AppIconColorExtractor.swift`）：新增内存缓存、在途请求去重、有界负缓存与 `bitmapRep` 落盘；修复颜色提取死循环并消除临时 `ColorArea` 分配。
- **同步与维护一致性**（`SyncEngine.swift`、`SyncDiffEngine.swift`、`SyncModels.swift`、`PasteDataStore+Mapping.swift`、`PasteDataStore+Maintenance.swift`）：统一秒级时间戳，修复 `group.cancelAll()`、元数据回填覆盖、`repairTagIfNeeded` 截断链接、删除回填 revision 校验与撤销墓碑清理。

---

## 三、Phase B：待修复的剩余 Bug 与性能项（代码审计遗留）

### P0（正确性与严重 Bug）
1. **代码高亮语言规则缺陷**（`Clipboard/Core/Code/CodeHighlighter.swift`、`CodeLanguageRules.swift`）
   - 补齐 `charLiterals`（修复 Rust 生命周期 `'a` 被误高亮）、`tagNamesAsKeywords`（HTML 标签）、`atSignAsKeyword`、`hexColorAsNumber` 支持，修正 SQL `"integerinto"` 拼写错误。
2. **编辑态 RTF 格式丢失与保存锁缺失**（`Clipboard/Features/Edit/ViewModel/EditTextLoader.swift`、`EditWindowController+Save.swift`）
   - 保留 RTF 编辑格式或提供明确的纯文本/富文本模式切换；保存期间锁定 UI 并在失败时弹窗提示。
3. **JSON 编辑器跨页选区复制 & 折叠范围越界**（`JSONViewportEditor+Input.swift`、`+Editing.swift`）
   - 修复跨页选区重复复制问题，校验折叠状态下的 `prepareEdit` 范围边界。
4. **数据计数、时间戳与同步复活 Bug**
   - `PasteDataStore.insertModel`：重复拷贝命中去重时不再错误递增 `totalCount`（`PasteInsertResult` 增加 `isInserted`）。
   - `PasteSQLManager+Write.swift`：修改 `group` / `alias` 时不覆盖内容更新 `timestamp`。
   - `SyncPendingDeletionsStore` / `SyncDiffEngine`：修复 `onlySyncPinned` 模式下取消置顶导致的云端记录复活问题。
5. **撤销截断、UniqueId 碰撞与大 RTF 降级**
   - `ClipUndoStore`：撤销恢复时不再将 `searchText` 截断至 2000 字符。
   - `PasteboardModel+Tool.swift`：修复 `generateUniqueId` 在纯文本/富文本、`.rtfd` 附件与 TIFF 前缀间的哈希碰撞。
   - `PasteboardTextPreparation`：`>256KB` RTF 不再直接按原始 UTF-8 解析（防止 RTF 控制字污染文本）。

### P1（性能瓶颈与响应度）
1. **JSON 编辑器每次击键全量拷贝多 MB `NSString`**（`JSONViewportEditor.swift`、`EditContentView.swift`、`TextStatistics.swift`）
   - 优化 `scheduleJSONAnalysis` 中 3 次连续 UTF-8 转换；合并 `TextStatistics` 4–5 遍全量扫描为单遍统计。
2. **存储统计阻塞写 Actor & VACUUM 后未重开读库**（`PasteSQLManager+Storage.swift`、`StorageSettingView.swift`）
   - 将只读统计查询迁出写 Actor；`vacuumDatabase()` 后调用 `PasteReadStore.shared.reopen()`；修改配额阈值时避免重复全库查询。
3. **迁移数据阻塞 OCR 与未规范化**（`PasteMigrationService.swift`）
   - 迁移图片时不再写入 `"图片"` 至 `searchText`（避免跳过后台 OCR），并统一规范化 `searchText`。
4. **高频热路径开销**
   - `HotKeyManager.tabDirection`：消除每次按键重复解码两次 JSON。
   - `FileThumbnailService`：将 `fileExists` / `icon(forFile:)` 移出主线程，并正确取消未完成的 `QLThumbnailGenerator` 请求。
   - `AppLogger`：避免在调用线程同步格式化 `Date`。

### P2（交互打磨与规范合规）
1. **剪贴板采集与拖拽边界**（`PasteBoard`、`PasteboardWritingItem`）：调整 `#if DEBUG` 全量读取与 15s 临时图片清理策略；支持多文件拖拽而非仅首文件。
2. **全局事件与通知收窄**（`AppDelegate.initLocalEvent`、`GeneralPreferencesCard`）：收窄 `.command` 键拦截范围；`didBecomeKeyNotification` 绑定具体窗口对象并移除轮询定时器。
3. **设置与本地化合规**（`AppearanceSettingsView`）：禁止同时关闭菜单栏图标与 Dock 图标；替换设置与状态栏中的硬编码中文字符串及遗留 `ByteCountFormatter`。

---

## 四、Phase C：外部 `.media/` CAS 图片存储与平滑迁移方案

### C1. 架构目标
将原始大图 / 二进制附件从 SQLite BLOB 剥离，消除数据库膨胀、`VACUUM` 锁表以及读取大 BLOB 导致的堆碎片，同时保留列表渲染的零磁盘 I/O 性能。

### C2. 内容寻址存储（CAS）布局
- **目录结构**：`~/Library/Application Support/com.crown.clipboard/.media/blobs/<sha256前2位>/<sha256>.<ext>`
- **数据库 Schema 扩展**（`PasteRecord`）：
  - `media_rel_path TEXT NULL`：相对 `.media/blobs/` 的路径。
  - `media_size INTEGER`：外部文件字节数。
  - **保留 `show_data`（5–15KB JPEG 缩略图）在 SQLite 中**：保证卡片列表滚动零额外文件打开开销。

### C3. 写入、读取与垃圾回收（GC）
- **原子写入**：先写 `.tmp` 临时文件 -> `FileManager.replaceItemAt` / 原子重命名至 CAS 目标路径 -> 更新 SQLite 记录（自动天然去重）。
- **零拷贝读取**：大图预览与降采样直接使用 `CGImageSourceCreateWithURL` 流式读取外部文件，避免中间 `Data` 堆分配。
- **延迟 GC（保护 `⌘Z` 撤销）**：删除记录时不立即删文件；后台周期任务扫描无数据库引用的孤儿文件，仅清理修改时间超过 **24 小时** 的文件。

### C4. 零停机增量迁移计划（`MediaMigrationCoordinator`）
1. **双态共存读路径**：读取大图优先判断 `media_rel_path` 是否存在；若为 `NULL` 则无缝回退读取历史 BLOB。
2. **新写入直出 `.media/`**：Schema 升级后所有新增图片直接落盘 `.media/`，不再写入大 BLOB。
3. **空闲/低功耗增量回填**：
   - 仅在应用空闲且非低电量模式下运行；
   - 每批处理 **10–20 条** 历史记录，外层包裹 `autoreleasepool`；
   - 迁移前校验磁盘剩余空间 `>= 500MB + 2 × 当前批次估算大小`；
   - 先原子落盘并校验文件存在，再将 SQLite 中的原大 BLOB 列置 `NULL` 并写入 `media_rel_path`。
4. **终局瘦身**：全部历史大 BLOB 清空后，在低峰期执行一次 `VACUUM` 并调用 `PasteReadStore.shared.reopen()` 回收磁盘与页缓存。

---

## 五、Phase D：五大架构级极致性能优化规划

### D1. OCR 独立 XPC / Helper 子进程隔离
- **问题**：Apple Vision + Espresso 神经网络权重与 C++ 上下文一旦在主进程加载即常驻 ~60–110MB 脏内存，且系统不会完全归还给 OS。
- **方案**：将 `VNRecognizeTextRequest` 封装到独立 `ClipboardOCRService.xpc`（或按需拉起的 Helper）；主进程通过 `NSXPCConnection` 传递图片路径或 `IOSurface`/共享内存；子进程闲置 **10 秒** 自动 `exit(0)`，使主进程常驻内存恒定维持在 **18–25 MB**。

### D2. 卡片渲染轻量化（彻底移除 `NSTextView` 与动态重排）
- **问题**：列表卡片复用或展示时使用 `NSTextView` 与 `snp.remakeConstraints` 触发频繁 Auto Layout 求解与 TextKit 开销。
- **方案**：
  - 文本卡片改用只读轻量视图（配置好行截断的 `NSTextField`、`CATextLayer` 或 CoreText 自绘）；
  - 固定子视图树与预设约束，通过 `isHidden` 与常量修改替代 `remakeConstraints`；
  - 列表行高与文本排版结果按 `uniqueId + width` 缓存。

### D3. Sync 引擎完全脱离主线程（`SyncWorker` Actor + 分片增量索引）
- **问题**：部分同步差异计算与调度仍在 `@MainActor` 执行，且全量单索引文件随历史增长变慢。
- **方案**：引入独立 `SyncWorker` Actor 承担拉取、diff、压缩与上传；云端索引拆分为按时间分片的增量日志，降低单次同步的内存峰值与主线程卡顿。

### D4. 基于间隙（Gap-based）的 `O(1)` 排序（`PasteOrder`）
- **问题**：拖拽重排置顶项时若触发连续整数重编号，需要批量更新多行数据库记录。
- **方案**：`sort_order` 采用大步长整数（如步长 `65536`）；每次拖拽插入仅计算前后邻居的中点值，单次更新 1 行即完成排序；仅当间隙耗尽（`< 2`）时才在后台触发一次局部重整。

### D5. 列表行轻量值模型（`ClipRowItem`）与懒加载
- **问题**：列表数据模型直接承载重型大字段与同步计算属性，增加内存常驻与主线程负担。
- **方案**：
  - 拆分列表专用不可变轻量值模型 `ClipRowItem`（仅含 ID、时间戳、类型标记、标签、应用标识与缩略图引用），按需再异步加载完整文本/富文本；
  - 为 `showData` 缩略图建立严格上限的 LRU 内存缓存；
  - 图标与主题色按可见区域懒加载；存储统计全部走只读查询通道。
