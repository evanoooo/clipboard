# 任务清单 v3：合并前收尾

> v1/v2 的修复计划见 `tasks/plan.md`。当前 HEAD：`37962fc`，Debug 构建通过。
> v2 的 21 项代码改动已全部落地，本清单只剩**手工回归**、**待决策**与**可选清理**。

## v2 完成归档

| # | 内容 | Commit |
|---|---|---|
| 1 | 撤销恢复保留 `hidden` | `2698d80` |
| 2 | `pasteModel` 标志残留 | `1d80bf1` |
| 19 | 暂停期间内容不补记 | `9db6715` |
| 3 | 数据库初始化失败弹告警 | `a9e2ebf` |
| 4 | MCP `search_text` 归一化 | `4bdc4a3` |
| 5 | 删除重复查询方法 | `2d44daa` |
| 6 | `org.nspasteboard.source` 判来源 | `3f72548` |
| 7 | Markdown 远程图片默认不加载 | `44bbea7` |
| 8 | 链接预览只拦点击导航 | `74ce455` |
| 9 | 删除无消费者的 `PasteMetadataCache` | `3bcc9c8` |
| 10 | 删除未接入的 `ExpirationSlider` | `4859857` |
| 11/12 | `DispatchQueue.main` → `RunLoop.main`（12 处） | `9f7f57b` `2c26ee6` |
| 13 | 计时器去强制解包 + 删死格式化代码 | `613b09e` |
| 20 | 删除未用的 Markdown 异步图片渲染 | `7954954` |
| 17 | 日志脱敏（关键词 / URL） | `ad2acc8` |
| 16 | 撤销栈 256MB → 64MB | `c42fa60` |
| 18 | 批量撤销部分失败不再静默丢弃 | `979b582` |
| 21 | 备份/导入提示改用本地化符号 | `d233e75` |
| 22 | 搜索归一化收敛为共享实现 | `484312c` |
| 23 | SHA-256 收敛为共享实现 + 删死成员 | `6dc28d2` |
| 24 | 忽略 `.DS_Store` + 移除冗余 translates | `37962fc` |
| 14 | 不做：882 行未越阈值，`AGENTS.md` 禁止纯组织性拆分 | — |
| 15 | 无需改：图标已是 path → bundle id → 名称兜底 | — |

---

## P0：合并前必须做的手工回归（需真机运行 App）

无测试 target，这是唯一的验收手段。按风险从高到低排列。

### 1. 撤销语义（改动最重，优先）

- [ ] chip 内删除一条已隐藏条目 → ⌘Z → 回到 chip，主列表**不**出现
- [ ] 主列表删除一条固定/隐藏条目 → ⌘Z → 恢复后仍保持原隐藏态
- [ ] 多选删除（含图片）→ ⌘Z → HUD 显示「已恢复 N 条」，顺序与位置正确
- [ ] 删除后再复制同样内容 → ⌘Z → 不产生重复行，保留现存行的位置
- [ ] 撤销失败场景：确认无内容恢复时是 beep 且记录仍在栈里（可再次 ⌘Z）
- [ ] 部分失败文案键 `undoDeletePartiallyFailed` 能在中英文下正常渲染

### 2. 采集正确性（P0 修复集中区）

- [ ] 自身「复制」动作不会重复入库
- [ ] 复制后 0.5s 内再从外部复制，新内容能被记录（不吞）
- [ ] 暂停 → 复制若干条 → 恢复：暂停期间内容**不**入库
- [ ] 定时暂停到期后自动恢复监听
- [ ] 滚动列表 / 打开模态弹窗期间复制，仍能采集（计时器已改 block 版 + `.common`）

### 3. 隐私

- [ ] 用 `com.apple.Safari` 来源探针验证忽略名单生效（Task 6）
- [ ] 本地 `python3 -m http.server 8000`，Markdown 预览含 `http://127.0.0.1:8000/x.png`：开关关闭时**无**请求
- [ ] 同一 Markdown 打开开关后图片正常加载
- [ ] 链接预览：页面内链接走系统浏览器、预览不跳转；`target=_blank` 不开新窗
- [ ] SPA 站点仍可预览、站内路由正常；反爬白屏仍提示
- [ ] 查看 Release/日志文件：无完整搜索关键词、无完整 URL（只有 `kwLen` / `host`）

### 4. 搜索 / 筛选 / 列表

- [ ] 两个窗口输入搜索：防抖正常，结果准确
- [ ] 主窗与浮窗滚动到底部能加载更多（`RunLoop.main` 下改为松手后触发，确认不丢）
- [ ] 筛选面板五种类型均可切换并正确过滤
- [ ] 分组 chip 筛选、日期筛选、来源应用筛选组合正常
- [ ] MCP 写入 `hello-world\nhttps://example.com` → `search_text` 为 `helloworldhttpsexamplecom`（Task 4）

### 5. 设置与导入导出

- [ ] 设置 → 通用 → 到期时间滑块：拖动、文案、刻度正常（中文 + 切英文各一次）
- [ ] 启动失败可见化：移走数据库目录并用同名文件占位 → 启动弹告警（Task 3）
- [ ] 导出数据库成功；导入正常备份成功且跳过重复条数正确
- [ ] 导入损坏备份：提示「无效的备份文件：缺少必要的列 xxx」

### 6. 其它入口

- [ ] JSON 编辑器、预览弹层、快捷键录制、开机自启、菜单栏、浮窗/主窗切换

---

## P1：待你决策（有代码影响，未开始）

### D1. 远程图片开关默认值

现状：默认**关闭**（隐私优先，Task 7 已实现）。若希望新用户开箱看到图片，只需改 `PrefKey.enableRemoteImages` 默认值。
建议：保持关闭，设置页已有开关。

### D2. 是否新增单元测试 target

现状：**全项目 0 个 XCTest**，这是最大的结构性风险；本轮 21 项改动全靠构建 + 手工验证。
建议：新增 target，优先覆盖 4 个纯逻辑点（都无 UI/DB 依赖，收益最高）：
1. `SearchTextNormalizer`（含全角、URL、CJK）
2. `ClipUndoStore` + `UndoOutcome` 状态机（部分失败回推）
3. `PasteAliasMigration`（重名/合并）
4. `JSONTransformer`
成本：需改 `project.pbxproj`（非同步组），约 1 个 XS 任务。

**调研结论（本轮未实施，待你确认）**：新建测试 target 需要手工编写 6 类 pbxproj 结构——`PBXNativeTarget`（`productType = "com.apple.product-type.bundle.unit-test"`）、`PBXSourcesBuildPhase`、`PBXFileReference`（`.xctest`）、`PBXGroup`、`XCBuildConfiguration` + `BuildConfigurationList`、`PBXTargetDependency`，还要把测试 target 加进 `Clipboard.xcscheme` 的 `TestAction`。

**两个风险**：
1. 纯手工编辑 pbxproj 容易出错——本轮的 `Data+Extension.swift` 就因为 `+` 字符未加引号导致工程无法解析，同类错误在这里会更难定位。
2. `SearchTextNormalizer` 已进 clipmcp 的同步组成员，测试 target 若也用同步组，需另设一个 `PBXFileSystemSynchronizedBuildFileExceptionSet`，否则会把整个 App 拖进测试 target。

**更稳的替代方案**：先用 SwiftPM 建一个只测纯逻辑的独立包（`Package.swift` + `Tests/`），不碰主工程；等纯逻辑都有覆盖后，再决定是否并入 Xcode。若认可，我可以直接做。

### D3. Task 5b：归一化实现收敛（已完成）

提交：`484312c`、`6dc28d2`。

原先 `clipmcp` 自带两份私有拷贝（`SearchText`、`Data.sha256Hex`），靠注释要求同步。现已把 `Core/Shared/SearchTextNormalizer.swift` 与 `Core/Extensions/Data+Extension.swift` 加入 clipmcp 的编译清单，删除两份拷贝，App 与 MCP 现在编译同一份代码。

**踩坑（重要）**：pbxproj 里含 `+` 的文件名（如 `Data+Extension.swift`）作为 `membershipExceptions` 条目时**必须加双引号**，否则工程文件解析失败，`xcodebuild` 报 `Unable to read project`。已用 `nm` 验证两个符号确实进入了 clipmcp 产物。

### D4. 更新通道

现状：Sparkle 已移除，**没有任何检查更新入口**。
建议：若不打算做自动更新，至少在设置/关于页显示版本号与仓库链接；若需要，另开功能任务。

---

## P2：可选清理（低风险，按需）

- [x] **`.DS_Store` 加入 `.gitignore`** — XS，避免每次 `status` 出现噪声（`tasks/` 是否入库另定）
- [x] **冗余的 `translatesAutoresizingMaskIntoConstraints = false`（2 处）** — 已删（`37962fc`）。SnapKit 的 `LayoutConstraintItem.prepare()` 会自动置 false，紧随其后的 `snp.makeConstraints` 让这两行成为冗余；`FilterPopoverContentView` 的 documentView 那处是 SnapKit 管不到的真实需求，保留
- [ ] **`getAppIcon` 的 `icon.size.width > 0` 守卫** — `NSWorkspace.icon(forFile:)` 不会返回零尺寸图标，属防御性代码，可留
- [ ] **4 处强制解包** — `URL(string: "https://")!` ×3、`applicationSupportDirectory` 的 `.first!` ×1，均为常量/系统保证，建议保留（不必为消除而加 fallback）

> 已核查：全项目无 `try!`、无 `as!`；无 `DispatchQueue` / `DateFormatter` / `NumberFormatter` / `MeasurementFormatter`。

---

## P3：候选专项（本轮不做，供后续排期）

1. **建立回归基线**：D2 落地后，把搜索归一化、撤销状态机、别名迁移、摘要渲染做成可脚本化验证
2. **clipmcp 与 App 的共享边界**：目前靠「复制 + 注释同步」，属于长期漂移源（同 D3）
3. **日志分级与保留策略**：脱敏已完成，但无轮转/上限，长期运行会持续增长
4. **`ChipButton.swift` 882 行**：若后续要改颜色面板或重命名逻辑，随功能改动顺带按职责拆分，而不是单独做搬移
