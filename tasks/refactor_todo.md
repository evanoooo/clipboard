# 架构重构与治理任务追踪清单

> 对应完整实施计划见 `tasks/refactor_plan.md`。  
> 严格遵循 `AGENTS.md` 规范（macOS 14.0+、Swift Concurrency、AppKit 优先、SnapKit 布局、常规提交规范）。

---

## 阶段一：稳定性与主线程优化（P0）

- [x] **Task 1: 消除核心层 `try!` 与非受控强制解包**
  - [x] 全项目无 `try!` 隐患（经全局检索已无残留）
  - [x] `PasteSQLManager.swift` 移除 `databaseDirectory` 的 `.first!` 强制解包，升级为 `URL.applicationSupportDirectory.appending(path:)`（Commit: `09e36a8`）
  - [x] `ClipboardSchema.swift` 移除 `appSupportDir` 的 `[0]` 强制下标，升级为 `URL.applicationSupportDirectory.appending(path:)`（Commit: `09e36a8`）
  - [x] `PasteboardModel+Pasteboard.swift` 替换剪贴板读取中的 `items[0]` 为安全的 `items.first`（Commit: `c380187`）
  - [x] 验证：`xcodebuild Debug` 顺利构建通过

- [x] **Task 2: 图像解码与大图缩略图异步化**
  - [x] `PasteboardModel.loadThumbnail()` 已使用 `Task.detached(priority: .userInitiated)` 后台解码图片
  - [x] `FileThumbnailService.swift` 已接入 `NSCache` 内存缓存（限额 100 项，20MB）
  - [x] `CardImageContentView.swift` 使用 `Task { @MainActor in await model.loadThumbnail() }` 实现主线程解耦

- [x] **Task 3: 优化粘贴执行并移除 `Thread.sleep` 阻塞**
  - [x] 全项目确认已无任何 `Thread.sleep` 阻塞调用
  - [x] `ClipActionService.swift` 已接入 `AXIsProcessTrusted()` 辅助功能权限检查与用户引导，通过 `WindowManager.shared.toggleWindow` 异步回调模拟键盘事件

- [x] **Task 4: 数据库记录删除与磁盘临时文件级联清理**
  - [x] 确认剪贴板内容（大图/文本）均存储于 SQLite BLOB 中，无本地脱管游离文件
  - [x] `PasteBoard.swift` 粘贴写入的临时目录已具备 10 秒后自动清理与再次写入前清理机制
  - [x] `AppDelegate.swift` 启动时异步清理残留的 `ClipboardDrag` 与 `ClipboardPaste` 临时目录（Commit: `f201811`）
  - [x] 验证：构建通过，临时文件具备自动生命周期管理

---

## 阶段二：测试体系与质量基准（P0）

- [x] **Task 5: 建立轻量级单元测试套件（覆盖核心纯逻辑）**
  - [x] 搭建 `Tests/Package.swift` 无侵入式测试工程（Commit: `81991d5`）
  - [x] 建立 `SearchTextNormalizer` 全套单测（基本归一化、URL数学符号保护、全角半角、CJK、分词去重）
  - [x] 建立 `JSONTransformer` 全套单测（JSON识别、有效性校验、紧凑化、两空格格式化、按键字母排序）
  - [x] 验证：运行 `swift run` 23/23 单元测试全部在 0.55s 内秒级通过，且主项目 `xcodebuild` 保持完全独立不受干扰

- [ ] **Task 6: 数据库迁移与 CRUD 内存测试**
  - [ ] 创建 `Tests/DatabaseMigrationTests.swift`
  - [ ] 验证：GRDB/SQLite 内存数据库 1 秒内完成 Schema 迁移及增删改查断言

- [x] **Task 7: 统一系统级日志与脱敏规范**
  - [x] `Logger.swift` 统一接入 `os.Logger(subsystem:category:)` 并使用 `OSAllocatedUnfairLock`
  - [x] `Logger.swift` 现代化日志目录路径获取为 `URL.applicationSupportDirectory`
  - [x] `Logger.swift` 增加超过 7 天历史日志文件的自动清理与轮转机制（Commit: `95fa85e`）
  - [x] 敏感搜索词与完整 URL 隐私脱敏已完成

---

## 阶段三：依赖注入与超级类拆解（P1）

- [x] **Task 8: 核心服务协议抽象（Protocol Abstraction）**
  - [x] 抽象 `ClipboardRepositoryProtocol`（Commit: `a9c78c3`）
  - [x] 抽象 `ClipboardActionProtocol`（Commit: `a9c78c3`）
  - [x] 抽象 `PasteboardMonitoringProtocol`（Commit: `a9c78c3`）
  - [x] 验证：`PasteSQLManager`、`ClipActionService`、`PasteBoard` 顺畅实现协议，修复 Swift 6 静态属性隔离警告，构建全绿

- [ ] **Task 9: 梳理 `AppDelegate` 与多窗口生命周期**
  - [x] 审查 `AppDelegate.swift`：实际仅 ~180 行，已非常精炼
  - [ ] 提取窗口显示/隐藏状态机，收拢 `WindowManager` 静态状态

- [ ] **Task 10: 拆分 `PasteDataStore` 数据存储与 UI 状态**
  - [ ] 提取 `ClipboardRepository`（专门负责 DB/Disk 交互）
  - [ ] 提取 `ClipboardFilterState`（专门管理搜索与分类状态机）
  - [ ] 清理 `NotificationCenter`，统一为 Combine 响应式订阅

---

## 阶段四：UI 表现层治理与重复消除（P1）

- [x] **Task 11: 统一 Card 与 Floating 视图的快捷交互层**
  - [x] 提炼共享的 `ClipUndoExecutor`，统一 ⌘Z 撤销和反馈 HUD 逻辑（Commit: `ab919c0`）
  - [x] 提炼 `HotKeyManager.tabDirection(for:)`，统一分类 Chip 切换快捷键路由（Commit: `ab919c0`）
  - [x] Card 与 Floating 双视图 KeyEvent 同步复用，消除重复代码

- [ ] **Task 12: 统一卡片与列表行内容渲染策略**
  - [ ] 提取通用的 `ClipContentRenderer`
  - [ ] CardContentView 与 FloatingCardRowView 复用渲染逻辑
  - [ ] 验证：新增内容展示样式单点生效

- [x] **Task 13: 接入 Diffable Data Source 提升列表刷新流畅度**
  - [x] `ClipMainViewController` 已接入 `NSCollectionViewDiffableDataSource<ClipSection, PasteboardModel>`
  - [x] 确认全局无 `asyncAfter` 延迟妥协，无暴力 `reloadData()`，由快照与单项配置精确更新
  - [x] 验证：列表新增、重排与删除具备平滑系统动画

---

## 阶段五：性能极致与工程现代化（P2）

- [ ] **Task 14: 引入 SQLite FTS5 全文搜索虚拟表**
  - [ ] 新增 DB 迁移版本 `v13` 创建 FTS5 表与触发器
  - [ ] 搜索逻辑由 `LIKE` 升级为 `MATCH`
  - [ ] 验证：5 万条数据下搜索延迟 < 15ms

- [x] **Task 15: 废弃 API 现代化与规范修正**
  - [x] 确认项目已完全使用 `NaturalLanguage`（`NLTokenizer`），无任何 `NSLinguisticTagger`
  - [x] 统一 `NScolor+Extension.swift` 大小写为 `NSColor+Extension.swift` 并改用原生 `replacing`（Commit: `431e3c0`）
  - [x] 确认 Swift 原生 `String` 截断均基于完整 Grapheme Cluster，无乱码风险

- [x] **Task 16: VoiceOver 无障碍与键盘导航增强**
  - [x] 为卡片 `CollectionViewItem` 和悬浮行 `FloatingCardRowView` 补齐无障碍角色、标签、内容与快捷操作指南（Commit: `0e0ad99`）
  - [x] 为 `EmptyStateView` 配置无障碍群组与状态朗读（Commit: `0e0ad99`）
  - [x] 验证：VoiceOver 可顺畅朗读来源应用、类型、快捷粘贴序号与自定义别名
