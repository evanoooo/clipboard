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

- [ ] **Task 4: 数据库记录删除时级联清理磁盘关联文件**
  - [ ] `PasteSQLManager+Write.swift` 检查是否有孤立本地文件残留
  - [ ] `PasteDataStore+Maintenance.swift` 维护清理时同步磁盘清理
  - [ ] 验证：删除带图记录后本地磁盘缓存同步释放

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

- [ ] **Task 7: 统一系统级日志与脱敏规范**
  - [ ] `Logger.swift` 接入 `os.Logger(subsystem:category:)`
  - [ ] 梳理全项目 `print`，统一为结构化日志
  - [ ] 确保搜索词与敏感 URL 在生产环境下脱敏输出

---

## 阶段三：依赖注入与超级类拆解（P1）

- [ ] **Task 8: 核心服务协议抽象（Protocol Abstraction）**
  - [ ] 抽象 `ClipboardRepositoryProtocol`
  - [ ] 抽象 `ClipboardActionProtocol`
  - [ ] 抽象 `PasteboardMonitoringProtocol`
  - [ ] 验证：数据消费方通过协议接入，支持 Mock 注入

- [ ] **Task 9: 拆解 `AppDelegate` 超级类**
  - [ ] 提取 `AppCoordinator` 负责窗口调度与交互中枢
  - [ ] 提取 `ServiceRegistrar` 负责服务实例与依赖组装
  - [ ] `AppDelegate` 精简至 < 100 行纯生命周期委托

- [ ] **Task 10: 拆分 `PasteDataStore` 数据仓储与 UI 状态**
  - [ ] 提取 `ClipboardRepository`（专门负责 DB/Disk 交互）
  - [ ] 提取 `ClipboardFilterState`（专门管理搜索与分类状态机）
  - [ ] 清理 `NotificationCenter`，统一为 Combine 响应式订阅

---

## 阶段四：UI 表现层治理与重复消除（P1）

- [ ] **Task 11: 统一 Card 与 Floating 视图的 Presenter 交互层**
  - [ ] 提炼 `ClipKeyActionRouter`，统一快捷键路由（1~9 快捷粘贴、空格预览等）
  - [ ] 消除 Card/Floating 各自的 `KeyEvent.swift` 冗余扩展
  - [ ] 统一右键上下文菜单构建与回调

- [ ] **Task 12: 统一卡片与列表行内容渲染策略**
  - [ ] 提取通用的 `ClipContentRenderer`
  - [ ] CardContentView 与 FloatingCardRowView 复用渲染逻辑
  - [ ] 验证：新增内容展示样式单点生效

- [ ] **Task 13: 接入 Diffable Data Source 提升列表刷新流畅度**
  - [ ] `ClipMainViewController` 接入差量刷新
  - [ ] 移除 `reloadData()` 和 `asyncAfter(0.1)` 延迟 Hack
  - [ ] 验证：列表新增、删除具有流畅系统动效

---

## 阶段五：性能极致与工程现代化（P2）

- [ ] **Task 14: 引入 SQLite FTS5 全文搜索虚拟表**
  - [ ] 新增 DB 迁移版本 `v13` 创建 FTS5 表与触发器
  - [ ] 搜索逻辑由 `LIKE` 升级为 `MATCH`
  - [ ] 验证：5 万条数据下搜索延迟 < 15ms

- [ ] **Task 15: 废弃 API 现代化与规范修正**
  - [ ] `NSLinguisticTagger` 升级为 `NaturalLanguage` 框架
  - [x] 统一 `NScolor+Extension.swift` 大小写为 `NSColor+Extension.swift` 并改用原生 `replacing`（Commit: `431e3c0`）
  - [ ] 修正 `String+Extension.swift` 截断逻辑，防止复合 Emoji 破损

- [ ] **Task 16: VoiceOver 无障碍与键盘导航增强**
  - [ ] 补齐 CollectionView 项的无障碍属性与读屏文案
  - [ ] 修正 `ClipCollectionView.keyDown` 事件转发
  - [ ] 验证：VoiceOver 正常朗读剪贴板类型与摘要
