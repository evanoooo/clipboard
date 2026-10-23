<p align="center">
    <div align="center"><img src="Clipboard/Resource/Assets.xcassets/AppIcon.appiconset/icon-256.png" width="135" /></div>
    <h2 align="center">Clipboard</h2>
    <div align="center">一款现代化、极速、低功耗、端到端加密的 macOS 原生剪贴板管理工具。</div>
    <div align="center"><a href="README.md">English</a> | <strong>中文</strong></div>
</p>

<img src="examples.png">

## 📥 下载与安装

下载最新版本发布包：[Releases](https://github.com/evanoooo/clipboard/releases/latest)

- **Apple Silicon (M系列)**：推荐下载 `Clipboard-*-arm64.dmg`（仅约 4.8MB，原生极致性能）
- **Intel 处理器**：推荐下载 `Clipboard-*-x86_64.dmg`（约 5.0MB，纯 x86 原生切片）
- **全架构通用**：提供 `Clipboard-*-universal.dmg`（双架构合一，适合全机型）

## 🔄 数据迁移 (Migration)

- **从 Paste.app 原生一键迁移 (Beta)**：v2.4.0 起支持直接在「设置」➔「存储」中安全扫描并导入 Paste.app 的历史剪贴板记录、图片、外部媒体和来源应用。内置 LZFSE/Deflate 原生解码、SHA-256 智能指纹排重、真实时间线平滑融入，写入前自动创建完整数据库快照备份。更多技术细节与离线演练脚本请参考：[Paste.app 迁移指南](docs/paste_migration_guide.md)。

---

## ✨ 核心功能与技术特性

### 🚀 Sparkle 2 自动更新与多架构分发
- **独立架构切片分发**：精准提供 Apple Silicon (`arm64`) 与 Intel (`x86_64`) 极致轻量切片及 Universal 双架构通用包，体积缩减约 45%，运行极速。
- **Ed25519 密码学签名校验**：采用 Curve25519 现代高强度非对称加密签名，严格保障更新包的完整性与真实性，彻底杜绝篡改。
- **应用内平滑静默升级**：基于原生 Sparkle 2 框架，自动识别硬件架构并精准匹配升级包，一键热替换重启。

### 🔐 端到端加密云端同步 (E2EE WebDAV Sync)
- **军事级端到端加密**：基于 **ChaCha20-Poly1305** 认证加密算法与 **PBKDF2-HMAC-SHA256**（100,000 轮安全哈希迭代 + 32 字节 CSPRNG 加密盐），数据在离开本机前全部高强度加密，主密钥绝不上云，WebDAV 服务端全程零知识。
- **Git 风格 2 字符前缀目录分片**：采用与 Git loose objects 类似的 `items/00/...` ~ `items/ff/...` 256 桶哈希分片架构，完美化解单目录下数万文件导致的 WebDAV 列目录超时，同时向下无缝兼容历史平铺结构。
- **智能增量 Diff 与 LWW 冲突裁决**：毫秒级完成全量 SQLite 与云端索引的比对，基于最后写入优胜（Last-Write-Wins）和哈希校验和智能判断待上传/待下载条目，零变动时网络往返 0 传输开销。
- **受控滑动窗口并发流水线 (Sliding Window)**：采用 Swift 结构化并发实现的滑动窗口 Worker 模型，恒定维持 $\le 3$ 个在飞任务，单个条目传输完毕即刻拉起下一个，彻底消除固定 Batch 模式下的木桶闲置气泡，传输效率大幅提升 30%~70%。
- **极低内存开销与 Payload 延迟加载**：比对与列表加载阶段完全排除大字段，仅在真正开始网络加密传输单项时按需点查，随用随释，万级记录全量同步内存占用恒定保持在 **<3MB**。
- **批量单事务极速落库**：从云端拉取还原数据时采用 SQLite 单事务批量提交，数千条记录落库只需数十毫秒，静默入库，不劫持前台列表也不触发多余刷新。
- **macOS 低功耗与休眠感知**：
  - 感知系统低电量模式（Low Power Mode）与发热保护，自动将防抖时间从 15s 拉长至 60s，减少 CPU 唤醒与无线发射功耗；
  - 监听系统休眠事件优雅挂起连接，唤醒后自愈并延迟重连增量同步。
- **多端墓碑删除同步与 30 天修剪**：一端删除自动云端打上墓碑标记并同步清理其余设备本地记录；云端索引自动修剪超过 30 天的历史墓碑，保障索引文件长期轻量。
- **即时云端资产看板**：毫秒级解析云端元数据，直观展示已备份记录总数、分组标签细分和富媒体类型占比。

### ⚡️ 极致性能与亚毫秒检索
- **覆盖索引极致优化**：构建 4 大复合覆盖索引（Covering Indexes），彻底杜绝全表扫描，万级历史记录多维筛选延迟稳定在 **0.2ms** 级别。
- **运行时 LRU 高亮缓存**：属性文本与代码语法高亮全局共享运行时 LRU 缓存，代码卡片全生命周期仅分词高亮一次，列表快速惯性滑动稳定保持 **120 FPS** 满帧。
- **零待机消耗**：后台空闲状态 CPU 占用保持 **0.0%**，近乎零电量消耗。

### 🏷️ 标签自由拖拽重排 (Drag-to-Reorder)
- 顶部自定义分类标签支持平滑左右拖拽手势重排（Safari/Chrome 标签页交互体验），附带原生触感反馈（Haptics）与弹性碰撞吸附动画。
- 系统首项“剪贴板”与尾部“＋”新建按钮安全锁止；排序与主界面、悬浮窗、右键筛选实时全局同步。

### 🎨 现代化卡片与元数据排版
- **来源应用完好保留**：修复归类或固定标签后丢失来源应用图标问题，置顶/分组后始终清晰保留来源 App 图标。
- **智能标题对齐**：设置别名时聚焦显示，自动隐去冗余空白。
- **底部微元数据升级**：集成 Apple SF Symbols 矢量图标、字符统计与代码语言识别（如 `Java · 48 个字符`）。

### 📋 全格式智能捕获
- 实时捕获并结构化存储纯文本、富文本、多行代码、图片、颜色值及文件流。
- 敏感数据保护机制（自动过滤 1Password、Keychain 等密码管理器与临时剪贴板内容）。

### 🔍 快速多维搜索与 FTS5 全文检索
- 支持快捷键直接按类型（图片、代码、链接、文件等）、时间跨度、来源应用与标签组合筛选。
- 500+ 条目截断计数与首屏即时发布机制，输入关键字即刻呈现首屏结果。

### 🪟 悬浮窗与极速快捷操作
- 双击项目直接粘贴，单选回车粘贴，`Shift + 回车` 粘贴为纯文本。
- 空格键呼出内容高保真预览，支持多行 JSON 语法格式化与高亮编辑。
- 拖拽卡片支持直接拖放进第三方 App 或拖放到顶部标签快速归类。

### 🛡️ 安全删除与隐私保护
- 支持确认删除与撤销恢复（⌘Z），自定义历史记录保留时长，数据完全本地持久化，无任何外部遥测上报。

---

## 💻 系统要求

- **操作系统**：macOS 14.0 或更高版本（深度适配 macOS Sonoma、macOS Sequoia 及后续版本）
- **架构支持**：原生支持 Apple Silicon (arm64) 与 Intel (x86_64) 双架构

---

## 🛠️ 本地构建与自动化测试

本项目内置严苛的自动化质量门禁与一键热升级脚本：

```bash
# 1. 运行全套 570 项自动化单元测试（覆盖加解密、索引模型、Diff裁决、FTS检索、滑动并发、Paste迁移、多架构分发等）
cd Tests && swift run

# 2. 一键编译 Release 生产包并热替换拉起应用
./scripts/build_and_install.sh
```

---

## ⌨️ 常用快捷键

| 快捷键 | 功能说明 |
| :--- | :--- |
| `ESC` | 关闭应用窗口 / 取消编辑 |
| `←` `→` | 在历史记录卡片间导航 |
| `空格` (Space) | 快速预览选中项（支持格式化编辑） |
| `↩` (Enter) | 直接粘贴选中项 |
| `Shift + ↩` | 以纯文本格式粘贴 |
| `⌘ + C` | 复制选中项到系统剪贴板 |
| `⌘ + Z` | 撤销最近一次删除操作 |
| `Delete` | 删除选中记录 |

---

## ❓ 常见问题 (FAQ)

### 1. 应用下载后提示损坏或无法打开？

1. 检查「系统设置」➔「隐私与安全性」➔「允许从以下位置下载的应用程序」选择 App Store 与被认可的开发者。
2. 在终端执行以下命令重置属性并重签：
```bash
sudo xattr -r -d com.apple.quarantine /Applications/Clipboard.app
sudo codesign --force --deep --sign - /Applications/Clipboard.app
```

### 2. WebDAV 云同步支持哪些网盘/服务？
任何遵循标准 WebDAV 协议的存储服务均原生支持，例如：
- 坚果云 (Jianguoyun)
- Nextcloud / ownCloud
- 阿里云盘 / WebDAV 挂载服务（如 AList）
- Synology 群晖 WebDAV Server
- 自建 Apache / Nginx WebDAV 服务

---

## 📄 许可证与开源致谢 (License & Attribution)

本项目遵循 **Creative Commons Attribution-NonCommercial 4.0 International Public License (CC BY-NC 4.0)** 开源协议。
本项目基于 [Ineffable919/clipboard](https://github.com/Ineffable919/clipboard) 开源项目演进开发，感谢原作者的开源贡献。
详情请参阅 [LICENSE](LICENSE) 文件。
