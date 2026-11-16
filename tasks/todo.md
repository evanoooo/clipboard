# Clipboard 优化与修复任务清单

> 对应方案文档：[plan.md](file:///Users/opm/Documents/data/code/clipboard/tasks/plan.md)
> 更新日期：2026-11-16

---

## 一、Phase A：已完成项（已验证：`2.4.7 (954)`，空闲 `18 MB` / 峰值 `26 MB`，650/650 测试通过）

- [x] **图片防 OOM**：`ImageDownsampler` 在全图解码前校验像素尺寸
- [x] **RTF/RTFD 列表瘦身**：`showData` 剥离 `NSTextAttachment` 并限制 16KB；缓存 `extractedPaths` 与 `uniqueId`
- [x] **NSCache 与内存修剪**：校准像素/属性成本，修复 `AppIconCache.trimMemory()` 并发竞争，完善运行时缓存清理
- [x] **冷启动内存优化**：延迟冷启动后台 OCR，限制并发为 2，`setup()` 与 OCR 后执行 `malloc_zone_pressure_relief`
- [x] **MCP 与迁移防护**：MCP 输出降采样（`<=1024px`）与文本截断（20K）；限制 LZFSE 解压缓冲并刷新 `totalCount`
- [x] **泄漏与窗口生命周期**：修复 `ShortcutRecorderView` 事件监听泄漏；编辑/JSON 窗关闭释放 `undoManager` 与响应链；`StorageInspectorSheet` 接入取消处理
- [x] **首次启动白屏修复**：设置/编辑/欢迎窗禁用 `isRestorable` 并补齐 `layoutIfNeeded()`
- [x] **查询与热路径优化**：新增 `idx_hidden_ts_app` / `idx_unpinned_ts` 索引，混合 FTS5+LIKE，`calculateTag` 后台化，复用 TextKit 测量栈，缓存 `NSDataDetector`
- [x] **链接元数据与主题色**：`LinkMetadataService` 增加缓存、去重与负缓存；修复 `AppColorService` 死循环与 `AppIconColorExtractor` 临时对象分配
- [x] **同步与存储一致性**：统一秒级时间戳，修复 `group.cancelAll()`、元数据回填覆盖、`repairTagIfNeeded` 截断、撤销墓碑清理与 `HUDManager` 竞态

---

## 二、Phase B：待修复 Bug 与性能项（代码审计遗留）

### P0：正确性与数据安全
- [x] **CodeHighlighter 规则补齐**：支持 `charLiterals`（Rust 生命周期）、`tagNamesAsKeywords`（HTML）、`atSignAsKeyword`、`hexColorAsNumber`，修正 SQL `"integerinto"` 拼写错误
- [x] **EditTextLoader & 保存锁**：修复编辑态丢失 RTF 格式问题；`EditWindowController+Save` 保存期间锁定 UI 并处理失败提示
- [x] **JSON 编辑器选区与折叠**：修复 `JSONViewportEditor+Input` 跨页选区重复复制及折叠状态下 `prepareEdit` 越界
- [x] **去重计数与时间戳一致性**：`PasteDataStore.insertModel` 命中去重时不递增 `totalCount`；修改 `group`/`alias` 时不更新内容 `timestamp`
- [x] **同步取消置顶复活**：修复 `onlySyncPinned` 模式下取消置顶导致的云端记录复活（`SyncPendingDeletionsStore` / `SyncDiffEngine`）
- [x] **撤销与标识碰撞**：`ClipUndoStore` 撤销恢复不截断 `searchText`；修复 `generateUniqueId` 在纯文本/RTFD/TIFF 前缀间的碰撞；`>256KB` RTF 不再按原始 UTF-8 解析

### P1：性能与响应度
- [x] **JSON 编辑器大文本优化**：消除每次击键全量拷贝多 MB `NSString`；合并 `scheduleJSONAnalysis` 连续 UTF-8 转换及 `TextStatistics` 多遍扫描
- [x] **存储统计与 VACUUM 重开**：`vacuumDatabase()` 后执行 `PasteReadStore.shared.reopen()`；配额阈值变更避免重复查库
- [x] **历史迁移规范化**：`PasteMigrationService` 迁移图片时不写入 `"图片"` 占位阻断 OCR，并统一规范化 `searchText`
- [x] **高频热路径减负**：`HotKeyManager.tabDirection` 避免每次按键解码两次 JSON；`FileThumbnailService` 文件检查离主线程并支持取消 `QLThumbnailGenerator`；`AppLogger` 将 `Date` 格式化推迟至后台队列

### P2：交互打磨与项目规范
- [x] **剪贴板与拖拽边界**：`FloatingHistoryView` 与 `ClipMainViewController+DataSource` 支持多文件拖拽
- [x] **事件与通知收窄**：收窄 `AppDelegate.initLocalEvent` `.command` 精确修饰键拦截；`GeneralPreferencesCard` 改用 `didBecomeActiveNotification` 并移除 2s 轮询定时器
- [x] **设置约束与本地化**：`AppearanceSettingsView` 禁止同时隐藏菜单栏图标与 Dock 图标；替换设置界面遗留 `ByteCountFormatter` 为现代 `FormatStyle`

---

## 三、Phase C：外部 `.media/` CAS 图片存储与迁移

- [x] **目录与 Schema 准备**：在应用数据目录下建立 `.media/blobs/<2位前缀>/<sha256>.<ext>`；`PasteRecord` 新增 `media_rel_path` 与 `media_size`（保留 `show_data` 缩略图）
- [x] **原子写入与零拷贝读取**：实现 `.tmp` 原子落盘去重；大图预览改用 `CGImageSourceCreateWithURL` 流式读取
- [x] **延迟 GC 机制**：实现孤儿文件后台清理（仅删除无引用且超过 24 小时的文件，保护 `⌘Z` 撤销）
- [x] **双态共存与增量迁移**：实现 `MediaMigrationCoordinator`（空闲/非低电量触发、10–20 条/批、`autoreleasepool`、磁盘余量校验 `>= 500MB + 2x batch`）
- [x] **历史库瘦身**：全量迁移完成后执行低峰 `VACUUM` + `PasteReadStore.shared.reopen()`

---

## 四、Phase D：五大架构级极致性能优化

- [x] **D1. OCR 进程隔离**：将 Vision/Espresso OCR 迁至独立 `--ocr-worker` 子进程，闲置 10 秒自动退出，隔离 60–110MB 脏内存
- [x] **D2. 卡片渲染轻量化**：移除列表卡片中的 `NSTextView` 与 `remakeConstraints`，改用 `CardAttributedTextView` 直绘 + 预设约束复用
- [x] **D3. SyncWorker Actor 化**：已将本地元数据扫描与 3-Way Diff 计算迁入独立 `SyncWorker` Actor 彻底脱离 `@MainActor`（云端索引分片可按需迭代）
- [x] **D4. Gap-based `O(1)` 排序**：`PasteOrder` 采用步长 `65536` 的间隙排序，单次拖拽仅更新 1 行
- [x] **D5. 轻量值模型与懒加载**：已实现 `showData` 4MB 有界 LRU 缓存（`ModelShowDataCache`）、可见区图标懒加载与只读连接存储统计（不可变 `ClipRowItem` 可作为后续增量演进）

---

## 五、Phase E：存储体积极致瘦身

- [x] **E1. 消除纯文本冗余 `show_data`**：纯文本不再落盘 `show_data`，列表加载由 `inlineData` / `search_text` 切片，并在建表迁移时清理历史纯文本冗余 `show_data`（立省 ~14.4 MB）
- [x] **E2. FTS5 External Content 核验**：已核验 `clip_fts` 已采用 `content='Clip', content_rowid='id'` 外部内容表
- [x] **E3. 缩略图 HEIC 编码**：`ImageDownsampler.generateThumbnailData` 优先采用 `UTType.heic`（quality `0.65`）编码，体积比 JPEG 缩减 ~40%–50%
- [x] **E4. 冷热数据分层归档**：超过 180 天未收藏历史冷记录自动归档至只读冷库 `ClipArchive.sqlite3`，支持联合检索、冷分页接力、点查回退与重复制回温
