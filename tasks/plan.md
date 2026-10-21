# Implementation Plan: 代码评审问题修复（v2）

> **修订说明（v2）**
> 基线从 `53793c4` 更新到 `216e324`。期间新增撤销功能、链接预览错误态、导入缺列兼容、删除确认开关，并移除了 Sparkle 自动更新。
> 本版基于新代码重新复核了 v1 的 14 条问题：**全部仍然存在**，另新增 1 条 Required（撤销恢复丢失 `hidden` 状态）和 3 条可选改进。
> 同时**更正 v1 的一处误判**：`PasteSQLManager.search` 不是死代码，它被 `insert` 用于写连接上的去重查询，必须保留。

## Overview

目标是把当前代码中已确认的问题按「撤销/采集正确性 → 数据一致性 → 隐私 → 规范 → 结构」处理完。共 15 个主任务 + 3 个可选任务，分 5 个阶段，每阶段一个验证检查点。

## 当前基线事实（已核对）

- 项目**没有测试 target**，`xcodebuild` 只验证编译；功能验证靠手工场景。
- scheme：`Clipboard`；工程：`Clipboard.xcodeproj`。
- `clipmcp` 是独立可执行目标，**只编译 6 个文件**（`AI/main.swift`、`MCPHandler`、`MCPTools`、`MCPTypes`、`Core/Shared/ClipboardSchema.swift`、`Core/Shared/SourceApp.swift`），`SearchTextNormalizer` 不在其中。
- 撤销链路：`ClipUndoStore`（内存栈，窗口隐藏即清空）→ `PasteDataStore.enqueueMutation`（串行写队列）→ `PasteSQLManager.restore`（单事务恢复）。
- Sparkle 已完全移除：`UpdateManager`、`UpdateSettingsView`、`appcast.xml` 均已删除，全局 `grep` 无残留引用。
- 新增本地化键 `undoDeleteSucceeded`、`linkPreviewFailed`、`linkPreviewEmpty` 在 `en`/`zh-Hans` 均已存在。
- 工作区仅剩未跟踪的 `.DS_Store` 与 `tasks/`，无未提交源码改动。

## 本轮变更审阅结论

**新增问题：**

1. **撤销恢复忽略 `ClipSnapshot.hidden`**。`restore` 插入时无条件写 `Col.hidden <- 0`，而快照里明明保存了 `hidden`。可复现的状态错误见 Task 1。
2. 撤销栈最多保留 256 MB 载荷（`maxPayloadBytes`），对剪贴板管理器偏高；删除大图后内存会一直占到窗口隐藏。
3. 链接预览新增 `[linkPreview] url=...` 日志，会把剪贴板里的完整 URL 写入磁盘日志（`[search] kw=` 同类问题此前已存在）。
4. **暂停期间复制的内容会在恢复时入库**（实现 Task 2 时发现）。`pause()` 只停轮询，`resume()` 不刷新 `changeCount`，恢复后第一次轮询会把暂停期间复制的最后一条内容补记入库，违背「暂停不记录」的预期。已作为 Task 19 插在 Task 3 之前完成。

**已确认无问题（不必再查）：**

- 窗口隐藏清空撤销栈：主窗与浮窗的所有隐藏路径都经过 `dismiss`，`removeAll()` 位置正确（窗口已不可见时提前返回，不需要清）。
- 撤销的写序：`undoLastDelete` 先 `awaitPendingMutations()` 再恢复，`enqueueMutation` 的链式顺序正确。
- 多选删除的撤销聚合：`recordUndo: false` + 单条 `.batch`，语义正确。
- `PasteOrder.promote/move` 返回的写入后序号与 `nextSortOrder` 子查询的实际值一致。
- 导入缺列兼容：`show_data` 缺失写 NULL，`alias_search` 由 `alias` 重新推导，方向正确。
- ⌘Z 不会抢文本撤销：`handleCommandKeyEvent` 首行 `guard focusRegion == .collection`，搜索框/别名编辑时事件交回系统。
- 删除确认开关：单条、多选、浮窗三处判断一致。

## Architecture Decisions

1. **撤销恢复以快照为准，不用"让用户看到"覆盖持久状态。**
   `hidden` 是持久状态（固定到分组但从主列表隐藏），恢复必须还原它，否则撤销会改变用户此前做过的另一次操作。

2. **MCP 归一化先用现有私有拷贝修复，不动工程配置。**
   `MCPTools.swift` 内已有与 `SearchTextNormalizer` 一致的 `SearchText.normalize`，只是写库时没用。收敛两份实现需要改 `project.pbxproj` 的同步组成员关系，列为可选任务。

3. **链接预览保留 JavaScript，只收紧导航。**
   新版 `PreviewWebView.inspectContent()` 依赖 `evaluateJavaScript` 判断白屏/反爬页；关掉 JS 会让这个能力失效，且 SPA 预览全空。只关闭自动弹窗、拦截新窗口、点击导航交给系统浏览器。

4. **隐私默认值取安全侧**：远程图片默认不加载，提供开关。

5. **不做顺手重构。** 除 Task 5（删除确认为无调用方的代码）和 Task 14（拆分附带的私有视图类型）外，不移动、不改名无关代码。

6. **一次任务一次提交**，Conventional Commits，scope 取具体模块。

## 前置准备（不产生提交）

1. `xcodebuild -project Clipboard.xcodeproj -scheme Clipboard -configuration Debug build` 必须成功，作为基线。
2. 确认可运行 Debug 版应用（手工验证需要真实 UI 与剪贴板）。
3. 手工验证会产生真实历史数据，测试后自行清理。

## Task List

### Phase 1: P0 — 撤销与采集正确性

#### Task 1: 撤销恢复保留 `hidden` 状态

**Description:** `PasteSQLManager.restore` 插入快照时固定写 `Col.hidden <- 0`，忽略 `ClipSnapshot.hidden`。当被永久删除的条目此前是「已固定到分组、但已从主列表隐藏」时，撤销会让它重新出现在主列表，改变了用户先前的另一次操作结果。

**根因证据:**
- `PasteFilterBuilder`: 主列表筛选为 `hidden == 0`，分组视图筛选为 `group == id`（不看 `hidden`）。
- `CardViewModel.deleteMultiple`: 分组内 `item.hidden == true` → 永久删除（`toPermDelete`）。
- `PasteSQLManager+Write.restore`: `Col.hidden <- 0`，`snapshot.hidden` 只存不读。

**实施要点:**
- 插入分支改为 `Col.hidden <- snapshot.hidden ? 1 : 0`。
- 合并分支（`uniqueId` 已存在）保持现状：那是删除后被重新复制的新行，不应把旧的隐藏状态套用到新行；在代码里补一句注释说明这个差异。

**Acceptance criteria:**
- [ ] 主列表删除一条已固定条目（变为隐藏、仍在 chip 内）→ 进入该 chip 永久删除 → ⌘Z：条目回到原 chip，且**不**出现在主列表。
- [ ] 普通条目（`hidden == false`）删除后撤销，仍在主列表原位置出现。
- [ ] 删除后重新复制相同内容再撤销，只合并分组/别名，不产生重复行。

**Verification:**
- [ ] 构建通过
- [ ] 手工复现上述三条路径，并在每步后检查 `sqlite3 ... "select id,hidden,\"group\" from Clip where unique_id='...'"`

**Dependencies:** None
**Files likely touched:** `Clipboard/Core/Data/PasteSQLManager+Write.swift`
**Estimated scope:** XS（1 文件）

#### Task 2: 修复「跳过自己写入」标志残留导致的外部复制丢失

**Description:** `PasteBoard` 用 `pasteModel != nil` 标记「这次 changeCount 变化是自己的写入」（`:129`、`:239`）。写入失败时标志不清除；标志一旦被消费就无条件跳过下一次变化，可能吞掉用户的下一次真实复制。

**实施要点:**
- 用 `private var ownWrite: (changeCount: Int, uniqueId: String)?` 替换 `pasteModel`（该字段仅在本文件使用）。
- 写入成功后记录**写完后**的 `pasteboard.changeCount`；仅在 `pasteboard.changeCount == ownWrite.changeCount` 时跳过。
- 若 changeCount 已更大，说明期间有新的外部复制 → 清除标志并继续正常入库。
- `writeMultipleToPasteboard` 返回 false 的路径必须清除标志（`defer` 或显式）。

**Acceptance criteria:**
- [ ] 应用内复制不产生重复历史条目。
- [ ] 复制后 0.5s 内立即从外部复制，外部内容被记录。
- [ ] 写入失败（如无可写路径的文件项）之后的外部复制被记录。

**Verification:**
- [ ] 构建通过
- [ ] 手工：应用内复制卡片 → 历史无新增重复
- [ ] 手工：应用内复制后立刻在编辑器复制文字 → 文字进入历史
- [ ] 手工：构造写入失败后复制文字 → 文字进入历史

**Dependencies:** None
**Files likely touched:** `Clipboard/Core/Data/PasteBoard.swift`
**Estimated scope:** Small（1 文件）

#### Task 3: 数据库初始化失败时给出可见反馈

**Description:** `AppDelegate.swift:79` 在 `PasteDataStore.setup()` 返回 false 时静默返回，应用正常启动但永远不再记录剪贴板。

**实施要点:**
- 失败时弹 `NSAlert`（`.critical`）：说明「历史数据库不可用，本次运行的复制不会被记录」，提供「打开数据目录」/「好」。
- 数据目录：`URL(fileURLWithPath: PasteSQLManager.databasePath).deletingLastPathComponent()`。
- 补一条 `log.error` 说明启动中止；不自动重试，避免循环。
- 新增 3 个本地化键（`en` + `zh-Hans`，`extractionState: "manual"`）。

**Acceptance criteria:**
- [ ] 失败时弹出可见告警，文案说明后果。
- [ ] 「打开数据目录」能在 Finder 打开该目录。
- [ ] 其余功能仍可打开，不崩溃、不循环重试。

**Verification:**
- [ ] 构建通过
- [ ] 手工：备份并移走 `~/Library/Application Support/com.crown.clipboard` → 在同一路径创建同名普通文件使 `createDirectory` 失败 → 启动看到告警
- [ ] 手工：还原后重启恢复正常

**Dependencies:** None
**Files likely touched:** `Clipboard/App/AppDelegate.swift`、`Clipboard/Resource/Localizable.xcstrings`
**Estimated scope:** Small（2 文件）

### Checkpoint: Phase 1
- [ ] 构建通过
- [ ] Task 1 三条手工路径通过（尤其是 chip 内删除后撤销不污染主列表）
- [ ] Task 2 三条手工路径通过
- [ ] Task 3 告警路径通过
- [ ] 用户确认后继续

### Phase 2: P0 — 数据一致性

#### Task 4: MCP 写入的 `search_text` 使用与 App 相同的归一化

**Description:** `MCPTools.swift:262` 把原文 `trimmingCharacters` 后写入 `search_text`，而 App 入库走 `SearchTextNormalizer.normalize`（丢弃空白与标点）。跨标点/空白边界的查询永远不命中。

**实施要点:**
- 写入改用文件内现有的 `SearchText.normalize(content)`。
- 在 `SearchText` 定义处补注释：说明它必须与 `Core/Shared/SearchTextNormalizer.swift` 保持一致，以及 clipmcp 为何不能直接引用（只编译 6 个文件）。

**Acceptance criteria:**
- [ ] 写入 `"hello-world\nhttps://example.com"` 后 `search_text` 为 `helloworldhttpsexamplecom`。
- [ ] App 内搜索 `helloworld`、`httpsexamplecom`、`hello world` 均命中。

**Verification:**
- [ ] 构建通过（两个目标）
- [ ] 手工：通过 clipmcp 执行一次 `tools/call` 写入
- [ ] 手工：`sqlite3` 查 `search_text`，再在 App 内做三种搜索
- [ ] 测试后删除该测试行

**Dependencies:** None
**Files likely touched:** `Clipboard/AI/MCPTools.swift`
**Estimated scope:** Small（1 文件）

#### Task 5: 删除确认无调用方的代码（修正版）

**Description:** `PasteSQLManager.getCount`、`PasteSQLManager.getCountByGroup` 已无任何调用方（全部走 `PasteReadStore`），且与只读通道的实现、日志格式完全重复。**注意：`PasteSQLManager.search` 不是死代码**，`insert` 在写连接上用它做 `unique_id` 去重，必须保留。

> 更正：初稿曾计划删除 `SourceAppCache.update` 里的 `guard apps[app.id] != nil`，称其「恒真」。复核后确认判断有误——`Optional` 与非可选值比较时，`nil != app` 为真，该守卫实际拦住的是「未知 id」，删掉会让 `apps` 与 `orderedIDs` 不一致。**保留，不改**。

**实施要点:**
- 删除 `PasteSQLManager+Query.swift` 的 `getCount` 与 `getCountByGroup`。
- 保留 `search`，并在其文档注释里写明「`insert` 用写连接查重，不能换成只读连接」（避免下次误删）。

**Acceptance criteria:**
- [ ] `grep -rn "sqlManager\.\(getCount\|getCountByGroup\)" Clipboard` 无结果。
- [ ] `search` 保留且被 `insert` 使用。
- [ ] 构建通过，无新增 warning。

**Verification:**
- [ ] 构建通过
- [ ] 手工：搜索、分组计数、chip 悬停计数、删除分组确认

**Dependencies:** None
**Files likely touched:** `Clipboard/Core/Data/PasteSQLManager+Query.swift`
**Estimated scope:** XS（1 文件）

#### Task 5b（可选）: 归一化实现收敛为一份

**Description:** `MCPTools` 的 `SearchText` 与 `Core/Shared/SearchTextNormalizer` 是两份相同实现，长期会漂移。

**实施要点:**
- 在 `project.pbxproj` 的 clipmcp `membershipExceptions` 中加入 `Core/Shared/SearchTextNormalizer.swift`。
- 删除 `MCPTools.swift` 底部私有 `SearchText`，改用 `SearchTextNormalizer`。
- 两个目标都必须编译通过——这同时验证成员关系改对了（改反会立刻失败）。

**Acceptance criteria:**
- [ ] 两个目标都编译通过。
- [ ] `grep -rn "enum SearchText" Clipboard` 只剩共享实现。
- [ ] Task 4 的搜索验证仍通过。

**Verification:**
- [ ] 构建通过（两个目标）
- [ ] 重复 Task 4 的手工验证
- [ ] 出现任何异常即回退本任务（功能已由 Task 4 修好）

**Dependencies:** Task 4
**Files likely touched:** `Clipboard.xcodeproj/project.pbxproj`、`Clipboard/AI/MCPTools.swift`
**Estimated scope:** Small（2 文件，含工程文件）

### Checkpoint: Phase 2
- [ ] 构建通过（两个目标）
- [ ] MCP 写入/搜索验证通过
- [ ] `grep` 检查通过
- [ ] 用户确认后继续

### Phase 3: P1 — 隐私加固

#### Task 6: 用 `org.nspasteboard.source` 识别来源应用

**Description:** 忽略名单与来源归属都依赖 `NSWorkspace.frontmostApplication`（`PasteBoard.swift:219`、`PasteboardModel+Pasteboard.swift:54`）。后台应用写入时前台是别的 App，忽略名单被绕过、来源归属错误。

**实施要点:**
- 读取 `pasteboard.string(forType: NSPasteboard.PasteboardType("org.nspasteboard.source"))`。
- 忽略名单匹配优先级：`sourceBundleID` > 前台应用 bundle id；路径匹配保留兜底。
- 来源解析：有 bundle id 时用 `NSRunningApplication.runningApplications(withBundleIdentifier:).first`，取不到回退前台应用。
- `PasteBoard.swift` 改为 `addNewItem(pasteboard, sourceApp: resolveSourceApp())`，避免模型内部再次回退到前台应用。
- 忽略判定处理一个易错点：已知来源 bundle id 但应用未运行时，**不要**拿前台应用的路径参与路径匹配，否则会把后台写入误判成前台应用而被错误忽略。

**Acceptance criteria:**
- [ ] 前台 Terminal、写入项 `org.nspasteboard.source = com.apple.Safari` 时，历史来源显示 Safari。
- [ ] Safari 在忽略名单时该写入被忽略；Terminal 在忽略名单时不影响该写入。
- [ ] 无 `org.nspasteboard.source` 的普通复制行为不变。

**Verification:**
- [ ] 构建通过
- [ ] 手工探针（应用需运行）：
      `swift -e 'import AppKit; let pb = NSPasteboard.general; pb.clearContents(); pb.declareTypes([.string, NSPasteboard.PasteboardType("org.nspasteboard.source")], owner: nil); pb.setString("probe-source", forType: .string); pb.setString("com.apple.Safari", forType: NSPasteboard.PasteboardType("org.nspasteboard.source"))'`
- [ ] 手工：忽略名单含 / 不含 Safari 两种情况各跑一次

**Dependencies:** None
**Files likely touched:** `Clipboard/Core/Data/PasteBoard.swift`、`Clipboard/Core/Models/Pasteboard/PasteboardModel+Pasteboard.swift`
**Estimated scope:** Small（2 文件）

#### Task 7: Markdown 远程图片默认不加载，并提供开关

**Description:** `MarkdownHTMLRenderer.swift:12` 的 CSP 允许 `img-src data: file: http: https:`。打开一条不可信 Markdown 预览会向内容里写的任意 URL 发请求（追踪像素 / IP 泄漏），`file:` 还允许渲染本机任意图片。

**实施要点:**
- `PrefKey` + `PasteUserDefaults` 新增 `enableRemoteImages`（默认 `false`）。
- `MarkdownHTMLRenderer` 的 CSP 按开关生成：关闭为 `img-src data:`；打开为 `img-src data: file: http: https:`（保持现有行为）。
- `PrivacySettingView` 增加一个 `PrivacyToggleRow`（用 `@AppStorage`，与相邻行一致），文案说明风险。
- 新增 2 个本地化键（标题 + 说明），`en` + `zh-Hans`。

**Acceptance criteria:**
- [ ] 默认设置下，含 `![](https://example.com/pixel.png)` 的预览不发起网络请求。
- [ ] 打开开关后远程图片正常显示。
- [ ] 关闭时 `file:` 图片也不加载。

**Verification:**
- [ ] 构建通过
- [ ] 手工：关闭开关预览远程/本地图片 Markdown，两者均不显示
- [ ] 手工：打开开关后远程图片显示
- [ ] 手工：用代理或断网确认关闭时无出站请求

**Dependencies:** None
**Files likely touched:** `Clipboard/Core/Utils/PrefKey.swift`、`Clipboard/Core/Utils/PasteUserDefaults.swift`、`Clipboard/Features/Clip/Preview/Render/MarkdownHTMLRenderer.swift`、`Clipboard/Features/Setting/View/Privacy/PrivacySettingView.swift`、`Clipboard/Resource/Localizable.xcstrings`
**Estimated scope:** Medium（5 文件）

#### Task 8: 收紧链接预览 WebView 的导航与弹窗（保留 JS）

**Description:** `PreviewWebView` 加载剪贴板任意 URL，未限制新窗口、未拦截导航。**不要关闭 JavaScript**：`inspectContent()` 用 `evaluateJavaScript` 判定白屏/反爬页，关闭会让该能力失效。

**实施要点:**
- `configuration.preferences.javaScriptCanOpenWindowsAutomatically = false`。
- 实现 `WKUIDelegate.createWebViewWith` 返回 `nil`。
- 实现 `WKNavigationDelegate.decidePolicyFor`：只允许初始 URL 的主框架导航；`linkActivated` 与其它主框架导航用 `NSWorkspace.shared.open` 后 `.cancel`（与 `PreviewMarkdownView` 对齐）。
- 注释写明保留 JS 的原因。

**Acceptance criteria:**
- [ ] 链接预览正常显示页面（含 SPA 站点）。
- [ ] 页面内 `window.open` / `target=_blank` 不打开新窗口。
- [ ] 点击页面内链接由默认浏览器打开，预览本身不跳转。
- [ ] 白屏/反爬页仍显示 `.linkPreviewEmpty` 提示。

**Verification:**
- [ ] 构建通过
- [ ] 手工：预览普通网页、SPA 站点、含 `target=_blank` 链接的页面、无内容页面各一次

**Dependencies:** None
**Files likely touched:** `Clipboard/Features/Clip/Preview/View/PreviewWebView.swift`
**Estimated scope:** Small（1 文件）

### Checkpoint: Phase 3
- [ ] 构建通过
- [ ] 来源识别、远程图片、预览导航三项手工验证通过
- [ ] 用户确认后继续

### Phase 4: P2 — 缓存一致性与工程规范

#### Task 9: 删除无消费者的标签类型缓存（原判“竞态”不成立）

**Description:** 原计划认为 `invalidateTagTypesCache(model)` 在插入前调用会缓存出缺失新类型的集合。复核后确认该问题**不存在**：`844c09b`（2026-09-03）已移除 `getAllTagTypes()` 的最后一个调用方，`cachedTagTypes` 无任何读者；筛选面板固定展示 5 种类型（`FilterPopoverViewController.swift:152`）。因此这 10 处失效调用与整个 `PasteMetadataCache` 都是无效代码，正确做法是删除而非打补丁。

**实施要点:**
- 删除 `Clipboard/Core/Cache/PasteMetadataCache.swift`（111 行）。
- 移除 6 个文件中 10 处调用：`PasteDataStore`、`+TextIngestion`、`+Maintenance`（6）、`+Mapping`、`PasteSQLManager+Transfer`、`StorageSettingView`。
- `PasteDataStore+Mapping` 的 `updateItemTag` 结果改为 `_ =`，DB 修复行为不变。

**Acceptance criteria:**
- [x] `grep -rn "PasteMetadataCache" Clipboard` 无结果。
- [x] 插入、删除、撤销、导入、清空历史的既有行为不变（仅移除无读者的写操作）。

**Verification:**
- [x] 构建通过（`BUILD SUCCEEDED`）
- [ ] 手工：复制文本 → 复制颜色 → 打开筛选，5 项类型均正常可切换

**Dependencies:** None
**Files touched:** 6 改 + 1 删
**Estimated scope:** Small

#### Task 10: 删除未接入的 `ExpirationSlider`（原判“本地化”不成立）

**Description:** `Expiration` / `ExpirationSlider` / 示例 `ContentView` 在文件外无任何引用（`grep -rn "ExpirationSlider" .` 仅命中自身；自 `40d2137` 添加后从未接入）。设置页实际使用 `HistoryTimeSlider`，其 `HistoryTimeUnit.displayText` 已本地化，语义完全重叠。原任务的“硬编码中文”因此只存在于弃用文件中，正确做法是删除而非补键。

**实施要点:**
- 删除 `Clipboard/Features/Setting/View/General/ExpirationSlider.swift`（402 行）。
- 不新增本地化键；不修改 `HistoryTimeSlider`。

**Acceptance criteria:**
- [x] 全仓无 `ExpirationSlider` / `Expiration` 引用。
- [x] 到期时间设置（通用页）仅保留 `HistoryTimeSlider`，中英文文案不变。

**Verification:**
- [x] 构建通过（`BUILD SUCCEEDED`）
- [ ] 手工：设置 → 通用 → 到期时间滑块拖动与文案正常
- [x] 全仓扫描：用户可见硬编码中文仅剩日志、搜索别名（有意保留）与 Task 15/17 范围

**Dependencies:** None
**Files touched:** 1 删
**Estimated scope:** Small

#### Task 11: 列表链路 Combine 调度器去除 `DispatchQueue.main`

**Description:** 项目规则禁止旧式 GCD，但列表刷新与滚动触底仍以 `DispatchQueue.main` 作为 scheduler。

**实施要点:**
- `ClipListPresenter.swift:63,74`、`ClipMainViewController+List.swift:164,172,182,190`：scheduler 改为 `RunLoop.main`。
- 不改变时间常量与合并语义；保留显式 `.receive(on:)`。

**Acceptance criteria:**
- [ ] 两文件不再出现 `DispatchQueue`。
- [ ] 搜索仍按 200ms 防抖，快速输入不产生逐字符查询。
- [ ] 滚动触底仍能加载更多且不重复触发。

**Verification:**
- [ ] 构建通过
- [ ] `grep -rn "DispatchQueue" Clipboard/Features/Clip/Common Clipboard/Features/Clip/Card` 无结果
- [ ] 手工：快速输入、滚动加载多页

**Dependencies:** None
**Files likely touched:** `Clipboard/Features/Clip/Common/ClipListPresenter.swift`、`Clipboard/Features/Clip/Card/Controller/ClipMainViewController+List.swift`
**Estimated scope:** Small（2 文件）

#### Task 12: 其余 Combine 调度器去除 `DispatchQueue.main`

**Description:** 与 Task 11 同类，剩余 6 处。

**实施要点:**
- `CardContentView.swift:102`、`FloatingFooterView.swift:77`、`FloatingWindowContentView.swift:106,115,124`、`WindowManager.swift:23`：scheduler 改为 `RunLoop.main`。

**Acceptance criteria:**
- [ ] 上述文件不再出现 `DispatchQueue`。
- [ ] 悬浮窗搜索、卡片内容刷新、窗口显隐行为不变。

**Verification:**
- [ ] 构建通过
- [ ] `grep -rn "DispatchQueue" Clipboard` 无结果
- [ ] 手工：悬浮窗搜索、卡片切换、窗口显示/隐藏

**Dependencies:** Task 11（同批次，建议顺序提交）
**Files likely touched:** `Clipboard/Features/Clip/Card/View/CardContentView.swift`、`Clipboard/Features/Clip/Floating/View/FloatingFooterView.swift`、`Clipboard/Features/Clip/Floating/View/FloatingWindowContentView.swift`、`Clipboard/Core/Utils/WindowManager.swift`
**Estimated scope:** Small（4 文件）

#### Task 13: 替换 `DateFormatter` / `NumberFormatter`，消除计时器强制解包

**Description:** 项目规则禁止 `DateFormatter`/`NumberFormatter`；`PasteBoard` 的计时器存在 `timer!`。

**实施要点:**
- `Int64.date()`（`:42`）：改为 `Date(timeIntervalSince1970: TimeInterval(self)).formatted(Date.ISO8601FormatStyle(timeZone: .current).year().month().day())`。**必须保留 `TimeZone.current`**（旧实现显式设置过，ISO8601 默认 GMT，漏掉会差一天）。
- `PasteboardModel.formatter`（`NumberFormatter(.decimal)`）：删除静态实例，调用处改 `value.formatted(.number)`。
- `PasteBoard.startListening`（`:57-67`）与 `pause(for:)`（`:88-96`）：改为 block 版 `Timer.scheduledTimer(withTimeInterval:repeats:) { [weak self] _ in ... }`，去掉 `timer!`/`resumeTimer!` 与 target/selector 强持有。

**Acceptance criteria:**
- [ ] `grep -rn "DateFormatter\|NumberFormatter" Clipboard` 无结果。
- [ ] `date()` 对同一时间戳输出与旧实现一致（`yyyy-MM-dd`，当前时区）。
- [ ] 暂停/恢复监听行为不变，计时器不重复创建。

**Verification:**
- [ ] 构建通过
- [ ] 对比命令：`swift -e 'import Foundation; for t in [0.0, 1700000000.0, Date().timeIntervalSince1970] { print(Date(timeIntervalSince1970: t).formatted(Date.ISO8601FormatStyle(timeZone: .current).year().month().day())) }'`
- [ ] 手工：暂停 5 秒恢复；暂停无限期再恢复；期间各复制一条

**Dependencies:** None
**Files likely touched:** `Clipboard/Core/Extensions/Int64+Extension.swift`、`Clipboard/Core/Models/Pasteboard/PasteboardModel.swift`、`Clipboard/Core/Data/PasteBoard.swift`
**Estimated scope:** Small（3 文件）

### Checkpoint: Phase 4
- [ ] 构建通过
- [ ] `grep -rn "DispatchQueue\|DateFormatter\|NumberFormatter" Clipboard` 无结果
- [ ] 类型筛选、到期时间、暂停/恢复手工验证通过
- [ ] 用户确认后继续

### Phase 5: P3 — 结构整理

#### Task 14: 不做——不拆 `ChipButton.swift`

**结论：** 保留现状。

**依据:**
- 文件 882 行，未越评审约定的大约 1000 行信号。
- `AGENTS.md`：「Do not split existing types that the current task does not otherwise need to change solely to satisfy this rule.」
- 三个辅助类与 `ChipButton` 强耦合（focus ring、颜色面板回调），抽出去需把 `private` 提升为 `internal`，属于纯搬移，不减少阅读者需同步的概念。

**若将来确需拆分:** 应随功能改动顺带进行，或先把颜色面板抽成独立复用组件（真正减少职责），而不是只换目录。

#### Task 15: 无需修改——图标解析已是 bundle id 优先

**结论：** 原判与代码不符。

**依据:** `getAppIcon(for:)`（`PrivacySettingView.swift:292-309`）已按 `path` → `bundleIdentifier` → `getFallbackIcon(name)` 三级解析；`getFallbackIcon` 只在应用已卸载、路径与 bundle id 都失效时使用，此时名称是唯一可用信息。`@State ignoredApps` 初始化时也按 bundle id 过滤重复项（`:38`、`:193-197`）。

### Phase 6（可选 / 待决策）

#### Task 16（可选）: 下调撤销栈的内存上限

**Description:** `ClipUndoStore.maxPayloadBytes = 256 MB`。快照持有 `Data`（写时复制，与模型共享缓冲区），删除大量图片后会一直保留到窗口隐藏。

**实施要点:** 下调到 64 MB，或改为按条数 + 单条上限；`evictIfNeeded` 逻辑不变。

**Acceptance criteria:** 连续删除 20 张大图后，撤销栈内存占用不超过上限；撤销最近一次仍正常。

**Verification:** 构建 + 手工删除多张大图后观察内存与撤销行为。

**Files:** `Clipboard/Core/Data/ClipUndoStore.swift`（XS）

#### Task 17（待决策）: 日志中的用户内容脱敏

**Description:** `[linkPreview] url=...` 把完整 URL 写入磁盘日志；`[search] kw=...` 同类。对剪贴板管理器，日志文件会积累用户内容。

**选项:**
- A. 只记录 URL host / 关键词长度。
- B. 保留现状，但仅在 DEBUG 构建落盘。
- C. 保留现状（若日志仅用于本地性能诊断且用户已知情）。

**Files:** `Clipboard/Features/Clip/Preview/View/PreviewWebView.swift`、`Clipboard/Core/Data/PasteDataStore.swift`（XS）

#### Task 18（可选）: 批量撤销部分失败时保留未恢复项

**Description:** `.batch` 中若某个子动作只恢复了一部分（如 `.ungrouped` 的某些 id 已不存在），只要整体 `restoredIds` 非空，动作就不会退回栈，未恢复的条目静默丢失撤销能力。

**实施要点:** 按子动作比较 `restored.count` 与 `itemCount`，未完全恢复的子动作重新入栈（或至少日志告警）。

**Files:** `Clipboard/Core/Data/PasteDataStore+Maintenance.swift`（S）

### Checkpoint: Complete
- [ ] 所有主任务验收项勾选
- [ ] 构建通过，无新增 warning
- [ ] 手工回归：采集、搜索、类型/分组筛选、复制粘贴、撤销（各删除形态）、暂停恢复、MCP 写入与搜索、Markdown 预览、链接预览、JSON 编辑
- [ ] `git --no-optional-locks status` 只含本计划涉及的文件
- [ ] 用户确认后合并

## 补充：实际执行中新增的修复

- **Task 20**：删除 `MarkdownAttributedRenderer.render` / `loadImages` / `markdownImageSource` 整条未使用链路（`7954954`）。
- **Task 21**：`PasteSQLManager+Transfer.swift` 自建 `localize(_:CVarArg...)` 换成 `String(localized:)`，移除字符串键与 `String(format:)`（`d233e75`）。

## Risks and Mitigations

| Risk | Impact | Mitigation |
|------|--------|------------|
| 无测试 target，回归靠手工 | Med | 每任务给出手工场景；开始前记录基线构建；建议后续补脚本化检查 |
| Task 1 的 `hidden` 语义理解偏差 | Med | 任务里给出完整复现路径与 SQL 断言；若产品认为"撤销应让条目可见"，改为记录该决策并调整验收 |
| 远程图片默认关闭被视为功能回退 | Med | 提供开关；默认值由用户最终决定（见 Open Questions） |
| Task 13 漏掉 `TimeZone.current` | Med | 该项实际为死代码，直接删除，不存在时区偏差 |
| Task 5b 改工程文件的成员关系 | Low | 可选任务；两个目标编译可立即暴露错误；失败即回退 |
| MCP 手工验证写入真实历史 | Low | 验证后删除测试行 |
| `RunLoop.main` 在跟踪/模态期间延后投递 | Low | 仅影响滚动触底预取时机（改为松手后触发）；需手工确认加载不丢

## Open Questions

1. **远程图片开关默认值**：本计划取「默认关闭」。是否接受？若希望默认开启，只需改默认值。
2. **Task 1 的产品语义**：撤销一条「已从主列表隐藏、仍在 chip 内」的条目，应该恢复为隐藏（本计划）还是让它重新出现在主列表？后者需删掉 `ClipSnapshot.hidden` 字段并在注释里说明。
3. **Task 17 日志脱敏**：已按保守方案实施（不记录关键词与 URL 内容）。若需要保留更多诊断信息（如 URL 路径哈希），可再调整。
4. **是否新增单元测试 target**（需改 `project.pbxproj`）：若同意，建议在 Phase 2 后插入，优先覆盖 `SearchTextNormalizer`、`PasteFilterBuilder`、`JSONTransformer`、`PasteAliasMigration`、`ClipUndoStore`。
5. **Task 5b 是否纳入本轮**。
6. **Sparkle 移除后是否还需要更新通道**（当前已无任何检查更新入口）：如需，另开功能任务，不在本计划内。
