# 架构重构与治理任务追踪清单

> 对应完整实施计划见 `tasks/refactor_plan.md` 与 `tasks/refactor_v2_plan.md`。  
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

- [x] **Task 6: 数据库迁移与 CRUD 内存测试**
  - [x] `Tests/Package.swift` 引入 `stephencelis/SQLite.swift` 0.17.0 纯内存测试依赖
  - [x] 编写 `MemoryDatabaseHelper.swift` 纯内存 SQLite 测试数据库工厂
  - [x] 编写 `SchemaMigrationTests.swift`（表结构创建、PRAGMA 列验证、user_version 升级、unique_id 唯一冲突断言）
  - [x] 编写 `CRUDOperationTests.swift`（记录单条/批量插入、sort_order 降序排序、alias 与 alias_search 归一化修改、hidden 软删除过滤、group 分组过滤、物理删除）
  - [x] 编写 `UndoRestoreTests.swift`（快照捕获、原 ID/sort_order 恢复校验、.immediate 事务异常回滚原子性断言）
  - [x] 验证：`swift run` 61/61 测试用例 1.02 秒内全绿通过，主项目 `xcodebuild` 编译无任何副作用（Commit: `e476c71`）

- [x] **Task 14: 引入 SQLite FTS5 全文搜索虚拟表（P0 - 性能极致）**
  - [x] 创建 `PasteFTSMigration.swift`：定义 `clip_fts` 外部内容虚表（`content='Clip'`, `content_rowid='id'`, `tokenize='trigram case_sensitive 0'`）
  - [x] 创建三向触发器 `clip_ai`、`clip_ad`、`clip_au` 保持增删改实时自动同步
  - [x] 升级 `PasteSQLManager.swift` 启动时自动建立虚表并执行全量索引 rebuild
  - [x] 升级 `PasteFilterBuilder.swift`：对 >=3 字符检索走 FTS5 倒排索引；对 <3 字符短词优雅降级为 LIKE，杜绝漏搜与语法报错
  - [x] 同步升级 `MCPTools.swift`：使 AI 工具检索同样享受毫秒级倒排索引加速
  - [x] 编写 `FTSTriggerTests.swift` 全套用例（增删改同步断言、中英文/代码子串匹配、跨列匹配、DSL子查询过滤）
  - [x] 验证：测试用例 75/75 耗时 0.26s 全绿通过；主工程 `Clipboard` 与 `clipmcp` 编译全部成功（Commit: `7510a5d`）

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

- [x] **Task 9: 梳理 `AppDelegate` 与多窗口生命周期**
  - [x] 审查 `AppDelegate.swift`：实际仅 ~180 行，结构精炼
  - [x] `WindowManager` 接入 `@MainActor` 严格主线程隔离，消除跨线程调度窗口隐患（Commit: `7a665b7`）
  - [x] `ClipPreviewPopover` 在 `cleanup` 中及时解绑全局键盘事件监听器，避免浮层关闭后事件泄露（Commit: `7a665b7`）
  - [x] 清理 `CardBottomView` 与 `CardContentView` 不必要的 `nonisolated(unsafe)` 绕过标记（Commit: `7a665b7`）

- [x] **Task 10: 拆分 `PasteDataStore` 数据存储与 UI 过滤状态机**
  - [x] 独立出 `ClipboardFilterState`（专门管理搜索条件 `criteria`、已编译 SQL 表达式 `currentFilter`、过滤计数及状态版本 `revision`）
  - [x] 重构 `PasteDataStore` 持有 `filterState`，将原散乱修改 `currentFilter` / `searchWord` 的逻辑收敛为单向状态机流转
  - [x] 解耦 `PasteModelType` 与大型 UI 模型 `PasteboardModel`，消灭循环依赖，实现轻量级跨平台复用
  - [x] 编写 `FilterStateTests.swift` 纯逻辑单测，覆盖空检索、FTS倒排触发、短词LIKE降级、多重复合条件、重置与手动重写
  - [x] 验证：98/98 单元测试秒级全绿通过；`Clipboard` 与 `clipmcp` 主工程构建全部通过（Commit: `1225d46`）

- [x] **Task 11: 数据同步与分页机制优化**
  - [x] 强化 `PasteDataStore.loadNextPage()` 与 `ClipListPresenter.appendNewItems()` 的 `uniqueId` + `id` 双重去重机制，杜绝数据倾斜造成的列表条目重复
  - [x] 强化版本屏障校验（`filterRevision` / `listRevision`），异步分页与搜索返回时自动丢弃过时（stale）脏数据
  - [x] 精确校准 `hasMoreData` 分页边界判定，防止页未填满或到达总数时发生无效翻页请求
  - [x] 编写 `PaginationTests.swift` 纯逻辑单测，覆盖双重去重、边界状态和版本屏障模拟
  - [x] 验证：107/107 单元测试秒级全绿通过；`Clipboard` 与 `clipmcp` 主工程构建全部通过（Commit: `db6d6df`）

- [x] **Task 12: 统一卡片与列表行渲染策略**
  - [x] 新建统一渲染中枢 `ClipContentRenderer.swift`，定义 `ClipContentKind` 与文本属性解析流水线
  - [x] 重构 `CardContentView.swift` 与 `FloatingCardRowView+Content.swift`，消除冗余重复的类型分支判断
  - [x] 统一富文本高亮、关键字匹配、背景色退化降级处理机制，保证网格与列表两种形态表现一致
  - [x] 编写 `ClipContentRendererTests.swift` 纯逻辑单测，验证各内容类型的解析映射
  - [x] 验证：115/115 单元测试秒级全绿通过；`Clipboard` 与 `clipmcp` 主工程构建全部通过（Commit: `92a8590`）

---

## 演进专项：原生语法高亮与代码语义支持（P2）

- [x] **Code Phase 1: 代码嗅探器恢复与 Nginx 规则扩展**
  - [x] 恢复 `CodeLanguage.swift`、`CodeLanguageDetector.swift`、`CodeLanguageRules.swift`
  - [x] 增加 `CodeLanguage.nginx` 枚举与 `displayName` 映射
  - [x] 增加 Nginx 配置指令、块作用域、`$` 变量等加权特征与词法规则
  - [x] 编写 `CodeDetectorTests.swift` 单测，覆盖 Nginx、Swift、Python、SQL、JSON、散文过滤
  - [x] 验证：125/125 单元测试全绿通过；主工程与 clipmcp 构建成功

- [x] **Code Phase 2: 原生 TextKit 词法着色器与动态主题构建**
  - [x] 实现 `CodeTheme`，基于系统语义色实现自适应深浅外观（免监听、免重启）
  - [x] 实现 `CodeHighlighter` 纯 Swift 状态机分词器（注释、字符串、Nginx 变量 `$host`、指令、数字及带单位处理）
  - [x] 融合搜索关键词黄色高亮机制，前景色与背景色完美叠加互不冲突
  - [x] 编写 `CodeHighlighterTests.swift` 单测，覆盖 Nginx 高亮、变量、注释、搜索词高亮叠加、大文本安全边界（140/140 单元测试全绿）
  - [x] 验证：主工程与 clipmcp 构建成功

- [x] **Code Phase 4: 完整单元测试套件与性能基线保障（P1）**
  - [x] 编写 `CodePerformanceTests.swift` 全套端到端套件与基准测试
  - [x] 覆盖复杂真实嵌套 Nginx 配置（多 upstream、ssl、proxy_pass、`$` 变量、开关与搜索词合成）
  - [x] 覆盖异常未闭合定界符（未闭合字符串、未闭合注释、未闭合花括号、纯空白）安全边界
  - [x] 覆盖中英文与多字节 Emoji（如 🚀、张三、你好世界）UTF-16 索引严格对齐无越界
  - [x] 覆盖多语言（JSON、Swift、SQL、Nginx）词法高亮断言
  - [x] 建立 10,000 字符性能基准：实测平均 6.16ms/次，远低于 60fps 单帧阈值 16.6ms
  - [x] 验证：170/170 单元测试全绿；主工程与 clipmcp 构建成功

- [x] **Code Phase 3: 挂载 ClipContentRenderer 与双端视图增强**
  - [x] `PasteboardModel` 接入 `detectedCodeLanguage` 懒加载与缓存（通过 `PasteboardModelRuntimeCache`）
  - [x] `ClipContentRenderer` 接入 `.code(language:)` 语义类型与 `CodeHighlighter` 自动调度
  - [x] 卡片视图（`CardStringContentView`）与悬浮行（`FloatingTextContentView`）接入等宽排版保护与回退
  - [x] 卡片头部（`CardHeadView`）实现代码语言（如 Nginx、Swift）徽章与副标题动态呈现
  - [x] 验证：144/144 单元测试全绿；主工程与 clipmcp 构建成功

- [ ] **Task 13: 强化错误处理与用户反馈**
  - [ ] 统一错误提示与关键失败恢复机制
