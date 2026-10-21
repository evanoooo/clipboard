# Implementation Plan: 全局代码重构与架构治理计划

> **版本**：v1.0  
> **基线**：基于整体代码评审结论（298 个 Swift 文件，~42,700 行代码）  
> **设计原则**：严格遵循 `AGENTS.md`（macOS 14.0+、Swift Concurrency、AppKit 优先、SnapKit 布局、无 force unwraps / `try!`、常规提交规范）。

---

## 1. 现状与重构目标

### 1.1 核心痛点与风险
1. **测试盲区**：项目内 0 个测试文件（无 Unit Test、无 UI Test），重构与新功能缺乏防护网。
2. **单例泛滥与紧密耦合**：`PasteSQLManager.shared`、`PasteDataStore.shared`、`PasteBoard.shared`、`ClipActionService.shared`、`HotKeyManager.shared` 及 `WindowManager` 静态方法互相穿插调用，无法 Mock 与独立测试。
3. **超级类（God Objects）膨胀**：`AppDelegate`、`PasteDataStore`、`ClipActionService` 承载了过多的业务状态与系统交互逻辑。
4. **两套视图严重重复**：Card 视图（`NSCollectionView`）与 Floating 视图（`NSTableView`）各有一套键盘处理、预览分发和内容渲染逻辑，维护成本翻倍。
5. **主线程掉帧与隐蔽 Crash**：数据库初始化使用 `try!`；大图缩略图在主线程同步解析；粘贴模拟使用 `Thread.sleep` 阻断线程。

### 1.2 阶段目标
- **阶段一（P0 - 稳定性防线）**：消灭所有 `try!` 与主线程卡顿源，落实崩溃防御与磁盘清理。
- **阶段二（P0 - 测试与质量基线）**：搭建首批无侵入单元测试，覆盖核心算法、数据迁移与 Undo 状态机。
- **阶段三（P1 - 依赖注入与架构解耦）**：协议化仓储与服务层，拆解 `AppDelegate` 与 `PasteDataStore`。
- **阶段四（P1 - UI 表现层治理与去重）**：统一 Card / Floating 交互逻辑，推行 Diffable 数据驱动更新。
- **阶段五（P2 - 性能极致与工程现代化）**：接入 SQLite FTS5 全文搜索、废弃 API 现代化、无障碍补齐。

---

## 2. 阶段任务拆解

### 阶段一：稳定性与主线程优化（P0）

#### Task 1: 消除核心层 `try!` 与非受控强制解包
- **目标文件**：
  - `Clipboard/Core/Data/PasteSQLManager.swift`
  - `Clipboard/Core/Data/PasteSQLManager+Migration.swift`
  - `Clipboard/Core/Models/Pasteboard/PasteboardModel+Pasteboard.swift`
- **实施要点**：
  1. `DatabaseQueue` 初始化替换为 `do-catch`，发生文件损坏/权限受限时触发安全告警弹窗或引导重置数据库路径，坚决杜绝崩溃启动。
  2. 剪贴板提取数据过程全面使用 `guard let` 代替强制解包 `!`。
- **验收标准**：
  - [ ] 模拟数据库文件损坏或只读权限时，App 弹出错误警告，不发生 Crash。
  - [ ] 搜索工程全局，Core 层无任何 `try!` 关键字。
- **Commit**：`fix(db): 移除数据库初始化 try 强解包并完善异常降级`

#### Task 2: 图像解码与大图缩略图异步化
- **目标文件**：
  - `Clipboard/Core/Services/FileThumbnailService.swift`
  - `Clipboard/Core/Services/AppIconColorExtractor.swift`
  - `Clipboard/Features/Clip/Card/View/CardImageContentView.swift`
- **实施要点**：
  1. 将大图 `NSImage` 解码与缩略图生成包装为 `Task.detached` / 异步任务，通过 `MainActor` 安全回传给 UI。
  2. `FileThumbnailService` 增加内存二级缓存（`NSCache<NSString, NSImage>`），避免列表复用时反复生成相同文件的预览图。
  3. `AppIconColorExtractor` 计算主色调移出主线程。
- **验收标准**：
  - [ ] 剪贴板连续复制 10 张 20MB 以上的高清截图，滚动 Card / Floating 列表时无主线程卡顿（保持 60/120fps）。
  - [ ] 相同文件重复展示时命中内存缓存，不重复请求 `QLThumbnailGenerator`。
- **Commit**：`perf(clip): 异步化大图解码与缩略图生成并接入内存缓存`

#### Task 3: 优化粘贴执行并移除 `Thread.sleep` 阻塞
- **目标文件**：
  - `Clipboard/Core/Services/ClipActionService.swift`
- **实施要点**：
  1. 废弃 `Thread.sleep(forTimeInterval:)`，使用 Swift Concurrency 的 `try await Task.sleep(nanoseconds:)` 或通过 `CGEventTap` / 定时回检查机制来协调键盘事件。
  2. 针对无 Accessibility（辅助功能）权限时，补充主动引导与友好错误返回，避免事件丢失。
- **验收标准**：
  - [ ] 执行普通粘贴与纯文本粘贴时，主线程无任何 Thread.sleep 阻塞。
  - [ ] 未授权辅助功能权限时，能够精准给出系统设置引导，不再静默失效。
- **Commit**：`refactor(action): 采用现代异步并发替换粘贴执行中的线程休眠`

#### Task 4: 数据库记录删除时级联清理磁盘关联文件
- **目标文件**：
  - `Clipboard/Core/Data/PasteSQLManager+Write.swift`
  - `Clipboard/Core/Data/PasteDataStore+Maintenance.swift`
- **实施要点**：
  1. `deletePaste` 和 `clearHistory` 逻辑中，收集已删除条目的本地缓存文件路径（如大图落地文件、临时附件缓存）。
  2. 在事务提交成功后，在后台队列安全删除对应磁盘文件，避免随着时间推移产生数百兆孤立文件。
- **验收标准**：
  - [ ] 复制多张图片入库 -> 删除对应记录 -> 确认本地 Application Support / Caches 对应文件被清理。
  - [ ] 清空全部历史记录后，数据表与磁盘目录均恢复干净状态。
- **Commit**：`fix(storage): 删除剪贴板记录时级联清理磁盘关联缓存文件`

---

### 阶段二：测试体系与质量基准（P0）

#### Task 5: 建立轻量级单元测试套件（覆盖核心纯逻辑）
- **目标文件**：
  - `Tests/SearchTextNormalizerTests.swift`（新建）
  - `Tests/ClipUndoStoreTests.swift`（新建）
  - `Tests/JSONTransformerTests.swift`（新建）
  - `Tests/PasteAliasMigrationTests.swift`（新建）
- **实施要点**：
  1. 采用无侵入方案建立测试支持（优先支持 SwiftPM `swift test` 或 Xcode 单独 Test Target）。
  2. 针对 `SearchTextNormalizer` 全角/半角、CJK 混合、URL 分词、特殊标点做全套断言。
  3. 针对 `ClipUndoStore` 的撤销栈深度上限（64MB）、状态恢复与部分失败场景做状态机单测。
  4. 针对 `JSONTransformer` 的格式化、压缩、按键排序逻辑进行全面覆盖。
- **验收标准**：
  - [ ] 运行测试命令全绿通过。
  - [ ] 覆盖至少 20 个关键边界测试用例。
- **Commit**：`test(core): 建立核心纯算法与撤销状态机的单元测试套件`

#### Task 6: 数据库迁移与 CRUD 内存测试
- **目标文件**：
  - `Tests/DatabaseMigrationTests.swift`（新建）
- **实施要点**：
  1. 利用 GRDB 的 `DatabaseQueue()`（内存数据库）模拟从 Schema v1 到 v12 的完整执行流程。
  2. 验证写入去重（unique_id）、排序顺序（PasteOrder.promote/move）、分类绑定迁移逻辑正确。
- **验收标准**：
  - [ ] 内存测试用例能在 1 秒内完成全量迁移与典型查询验证。
- **Commit**：`test(db): 增加 GRDB 内存数据库完整迁移与写入回归测试`

#### Task 7: 统一系统级日志与脱敏规范
- **目标文件**：
  - `Clipboard/Core/Utils/Logger.swift`
- **实施要点**：
  1. 引入统一的 `os.Logger(subsystem:category:)`，按 `database`、`monitor`、`ui`、`mcp` 等细分分类。
  2. 废弃全工程随意散落的 `print`。
  3. 对剪贴板敏感信息（如密码、完整 URL Token、敏感搜索词）提供统一脱敏打印策略。
- **验收标准**：
  - [ ] 控制台使用 Console.app 可按 Subsystem 过滤筛选 Clipboard 日志。
  - [ ] Release 模式下无敏感剪贴板文本泄露至标准输出。
- **Commit**：`refactor(logger): 接入 os.Logger 统一分类日志并强化隐私脱敏`

---

### 阶段三：依赖注入与超级类拆解（P1）

#### Task 8: 核心服务协议抽象（Protocol Abstraction）
- **目标文件**：
  - `Clipboard/Core/Shared/Protocols/ClipboardRepositoryProtocol.swift`（新建）
  - `Clipboard/Core/Shared/Protocols/ClipboardActionProtocol.swift`（新建）
  - `Clipboard/Core/Shared/Protocols/PasteboardMonitoringProtocol.swift`（新建）
- **实施要点**：
  1. 抽象 `ClipboardRepositoryProtocol`：涵盖增删改查、排序、分页、撤销。
  2. 抽象 `ClipboardActionProtocol`：涵盖粘贴、拷贝、类型转换。
  3. `PasteSQLManager`、`PasteDataStore` 和 `ClipActionService` 分别实现对应协议。
- **验收标准**：
  - [ ] 业务 Controller 不再直接强引用 `PasteSQLManager.shared`，改为依赖协议接口。
- **Commit**：`refactor(core): 提取核心仓储与动作服务协议接口`

#### Task 9: 拆解 `AppDelegate` 超级类
- **目标文件**：
  - `Clipboard/AppDelegate.swift`
  - `Clipboard/Core/Bootstrap/AppCoordinator.swift`（新建）
  - `Clipboard/Core/Bootstrap/ServiceRegistrar.swift`（新建）
- **实施要点**：
  1. 将应用启动时的组件实例化与环境初始化收拢到 `ServiceRegistrar`。
  2. 将多窗口生命周期调度与状态栏集成解耦到 `AppCoordinator`。
  3. `AppDelegate` 精简至仅保留系统事件回调入口（< 100 行）。
- **验收标准**：
  - [ ] `AppDelegate.swift` 保持极简生命周期转发，业务初始化逻辑内聚于协调器中。
- **Commit**：`refactor(app): 拆分 AppDelegate 启动装配与窗口协调职责`

#### Task 10: 拆分 `PasteDataStore` 数据仓储与 UI 状态
- **目标文件**：
  - `Clipboard/Core/Data/PasteDataStore.swift`
  - `Clipboard/Core/Data/ClipboardRepository.swift`（新建持久化适配）
  - `Clipboard/Core/Models/ClipboardFilterState.swift`（新建 UI 筛选状态机）
- **实施要点**：
  1. `ClipboardRepository` 专门负责与 `PasteSQLManager` 通信、数据转换与异步读写。
  2. `ClipboardFilterState` 专门管理搜索关键字、激活分类 Chip、时间跨度筛选等瞬态 UI 状态。
  3. 淘汰 `NotificationCenter` 的非结构化通知，全部由 Combine / `@Observable` 响应式流替代。
- **验收标准**：
  - [ ] 状态变更具备单向流动性，消灭数据冲突和时序错位。
- **Commit**：`refactor(store): 拆分持久化仓储与 UI 筛选状态机并统一响应式流`

---

### 阶段四：UI 表现层治理与重复消除（P1）

#### Task 11: 统一 Card 与 Floating 视图的 Presenter 交互层
- **目标文件**：
  - `Clipboard/Features/Clip/Common/ClipListPresenter.swift`
  - `Clipboard/Features/Clip/Card/Controller/ClipMainViewController+KeyEvent.swift`
  - `Clipboard/Features/Clip/Floating/Controller/ClipFloatingViewController+KeyEvent.swift`
- **实施要点**：
  1. 提炼通用的 `ClipKeyActionRouter`，统一处理数字快捷粘贴（1~9）、方向键选择、空格预览、回车粘贴、Command+Z 撤销等核心热键。
  2. 消除卡片视图与浮动视图中几乎一模一样的两套 `KeyEvent.swift` 扩展。
- **验收标准**：
  - [ ] 修改一处键盘快捷键映射规则，Card 视图与 Floating 视图同步生效，无分化差异。
- **Commit**：`refactor(ui): 抽取统一的剪贴板按键事件路由与业务调度器`

#### Task 12: 统一卡片与列表行内容渲染策略
- **目标文件**：
  - `Clipboard/Features/Clip/Card/View/CardContentView.swift`
  - `Clipboard/Features/Clip/Floating/View/FloatingCardRowView+Content.swift`
  - `Clipboard/Features/Clip/Common/ClipContentRenderer.swift`（新建）
- **实施要点**：
  1. 提炼富文本高亮、图片自适应、文件信息展示、颜色预览块、URL Link 预览的内容构建协议。
  2. 让卡片网格项和悬浮列表行共享一套内容视图配置模型，杜绝两处 `switch type` 分支代码的维护冗余。
- **验收标准**：
  - [ ] 针对某种新型剪贴板内容（例如颜色块或代码片段），仅需扩展单处内容渲染协议即可全端支持。
- **Commit**：`refactor(view): 统一 Card 与 Floating 的内容类型渲染逻辑`

#### Task 13: 接入 Diffable Data Source 提升列表刷新流畅度
- **目标文件**：
  - `Clipboard/Features/Clip/Card/Controller/ClipMainViewController+List.swift`
  - `Clipboard/Features/Clip/Floating/View/FloatingHistoryView.swift`
- **实施要点**：
  1. 废弃暴力的 `reloadData()`，为 `NSCollectionView` 引入 `NSCollectionViewDiffableDataSource`（或基于标识符计算差量）。
  2. 新增剪贴板内容时使用动画插入首项，删除记录时保持选中焦点平滑过渡。
  3. 彻底移除 `DispatchQueue.main.asyncAfter(deadline: .now() + 0.1)` 这种时序妥协代码。
- **验收标准**：
  - [ ] 新增或批量删除条目时，列表具备平滑的动画效果，滚动不被打断，焦点不跳变。
- **Commit**：`perf(list): 接入差量数据源替换全局重载并优化动画刷新`

---

### 阶段五：性能极致与工程现代化（P2）

#### Task 14: 引入 SQLite FTS5 全文搜索虚拟表
- **目标文件**：
  - `Clipboard/Core/Data/PasteSQLManager+Query.swift`
  - `Clipboard/Core/Data/PasteSQLManager+Migration.swift`
- **实施要点**：
  1. 新增数据库迁移版本 `v13`，创建 `clip_fts`（使用 FTS5 虚拟表并挂载 SQLite 触发器自动同步）。
  2. 搜索查询从低效的 `LIKE '%text%'` 切换为 `MATCH` 全文索引检索。
  3. 针对 CJK 中文分词优化，支持更精确的前缀匹配和分词命中。
- **验收标准**：
  - [ ] 在 50,000 条剪贴板历史记录的大数据库下，搜索响应时间从 >300ms 降低至 <15ms。
- **Commit**：`perf(db): 建立 FTS5 虚拟表全文搜索提升大数据量检索性能`

#### Task 15: 废弃 API 现代化与规范修正
- **目标文件**：
  - `Clipboard/Core/Data/PasteDataStore+TextIngestion.swift`
  - `Clipboard/Core/Extensions/NScolor+Extension.swift`
  - `Clipboard/Core/Extensions/String+Extension.swift`
- **实施要点**：
  1. 将废弃的 `NSLinguisticTagger` 迁移为现代的 `NaturalLanguage`（`NLLanguageRecognizer` / `NLTokenizer`）。
  2. 修正 `NScolor+Extension.swift` 文件命名为 `NSColor+Extension.swift`，确保大小写统一。
  3. 优化 `String+Extension.swift` 截断逻辑，以 `String.Index` 和 Grapheme Cluster 为基准截断，防止 Emoji 字符拆裂。
- **验收标准**：
  - [ ] 编译无任何已废弃 API 的编译器警告。
  - [ ] 包含复合 Emoji（如 👨‍👩‍👧‍👦）的字符串截断后无乱码或问号符号。
- **Commit**：`refactor(core): 现代化废弃 API 替换并修复 Emoji 字符截断`

#### Task 16: VoiceOver 无障碍与键盘导航增强
- **目标文件**：
  - `Clipboard/Features/Clip/Card/View/ClipCollectionView.swift`
  - `Clipboard/Features/Clip/Card/View/CollectionViewItem.swift`
  - `Clipboard/Features/Clip/Common/EmptyStateView.swift`
- **实施要点**：
  1. 为每个剪贴板卡片和浮动行配置 `accessibilityLabel`、`accessibilityValue` 和 `accessibilityHelp`。
  2. 修复 `ClipCollectionView.keyDown` 拦截后未调 `super` 导致系统无障碍辅助失效的问题。
- **验收标准**：
  - [ ] 开启 macOS VoiceOver 时，可通过键盘顺畅浏览剪贴板内容、朗读类型及来源应用。
- **Commit**：`feat(a11y): 完善剪贴板卡片 VoiceOver 标签与系统无障碍导航`

---

## 3. 任务排期与里程碑追踪

| 阶段 | 任务编号 | 重点内容 | 预期周期 | 交付物 |
|---|---|---|---|---|
| **Phase 1** | Task 1 ~ 4 | 安全崩溃防御、异步解包、磁盘清理 | 2 天 | 零 `try!`，无主线程掉帧卡顿 |
| **Phase 2** | Task 5 ~ 7 | 纯逻辑单测套件、内存 DB 迁移测试、os.Logger | 2 天 | 自动化测试命令与基线防护网 |
| **Phase 3** | Task 8 ~ 10 | 核心协议提取、AppDelegate 瘦身、仓储状态解耦 | 3 天 | 松耦合架构，支持无单例注入 |
| **Phase 4** | Task 11 ~ 13 | Card/Floating 逻辑收敛、统一渲染、Diffable 刷新 | 3 天 | 消除冗余代码 1000+ 行，平滑刷新 |
| **Phase 5** | Task 14 ~ 16 | FTS5 全文索引、API 现代化、VoiceOver 无障碍 | 2 天 | 海量数据毫秒级检索，全无警告 |

---

## 4. 实施验证原则

1. **单次改动单次验证**：每个 Task 执行完毕后，必须先运行 `xcodebuild build`（或 SwiftPM 测试），确保编译通过与既有行为不受破坏，再行提交。
2. **渐进式演进，禁止破坏性重写**：保留原有的公共方法与行为特征，通过分阶段协议提取和桥接，平滑完成架构升级。
3. **真实体验验收**：涉及主线程异步化、快捷键路由、Diffable 刷新的改动，必须启动应用进行真机多场景交互回归验证。
