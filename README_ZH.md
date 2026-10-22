<p align="center">
    <div align="center"><img src=Clipboard/Resource/Assets.xcassets/AppIcon.appiconset/icon-256.png width=135  /></div>
    <h2 align="center">Clipboard</h2>
    <div align="center">一款现代化、极速、低功耗的 macOS 剪贴板管理工具，助您更高效地管理与利用剪贴板历史记录。</div>
    <div align="center"><a href="https://github.com/Ineffable919/clipboard/blob/master/README.md">English</a> | <strong>中文</strong></div>
</p>

<img src="examples.png">

## 📥 下载与安装

下载最新版本 [releases](https://github.com/Ineffable919/clipboard/releases/latest)

---

## ✨ 核心功能与最新特性

- ⚡️ **极致性能与亚毫秒检索**：
  - 构建 4 大复合覆盖索引（Covering Indexes），彻底杜绝全表扫描，万级历史记录多维筛选延迟稳定在 **0.2ms** 级别。
  - 属性文本与语法高亮运行时 LRU 缓存，代码卡片全生命周期仅分词一次，快速滑动稳定保持 120 FPS。
  - 待机 CPU 占用 **0.0%**，近乎零电量消耗。
- 🏷️ **标签自由拖拽重排 (New)**：
  - 顶部自定义分类标签支持平滑左右拖拽手势重排（Safari/Chrome 标签页交互体验），附带原生触感反馈（Haptics）与弹性碰撞吸附动画。
  - 系统首项“剪贴板”与尾部“＋”新建按钮安全锁止；排序与主界面、悬浮窗、右键筛选实时全局同步。
- 🎨 **现代化卡片与元数据排版 (New)**：
  - 修复固定标签后丢失来源应用图标问题，置顶/归类后始终清晰保留来源 App 图标。
  - 智能标题展示：设置别名时聚焦显示，自动隐去冗余空白；
  - 底部微元数据升级：集成 Apple SF Symbols 矢量图标、字符统计与语言类型显示（如 `Java · 48 个字符`）。
- 📋 **全格式剪贴板智能捕获**：
  - 实时捕获并结构化存储纯文本、富文本、多行代码、图片、颜色及文件流。
  - 敏感数据保护机制（自动过滤 1Password、Keychain 等密码管理器与临时剪贴板内容）。
- 🔍 **快速多维搜索与 FTS5 全文检索**：
  - 支持快捷键直接按类型（图片、代码、链接、文件等）、时间跨度、来源应用与标签组合筛选。
- 🪟 **悬浮窗与极速快捷操作**：
  - 双击项目直接粘贴，单选回车粘贴，`Shift + 回车` 粘贴为纯文本。
  - 空格键呼出内容高保真预览，支持多行 JSON 语法格式化与高亮编辑。
  - 拖拽卡片支持直接拖放进第三方 App 或拖放到顶部标签快速归类。
- 🛡️ **安全删除与隐私配置**：
  - 支持确认删除，自定义历史记录保留时长，数据完全本地持久化，无任何外部网络上报。

---

## 💻 系统要求

- macOS 14.0 或更高版本（深度适配 macOS Sonoma、Sequoia 及以上版本）
- 原生支持 Apple Silicon (arm64) 与 Intel (x86_64) 双架构

---

## 🛠️ 本地构建与自动化测试

本项目内置完备的自动化质量门禁与一键热升级脚本：

```bash
# 1. 运行全套 281 项自动化单元测试
cd Tests && swift run

# 2. 一键编译 Release 生产包并热替换拉起
./scripts/build_and_install.sh
```

---

## ⌨️ 常用快捷键

- `ESC`：关闭应用窗口 / 取消编辑
- `←` `→`：在历史记录卡片间导航
- `空格`：快速预览选中项
- `↩`：直接粘贴选中项
- `Shift + ↩`：以纯文本格式粘贴
- `⌘ + C`：复制选中项到系统剪贴板
- `Delete`：删除选中记录

---

## ❓ 常见问题 (FAQ)

### 应用下载后提示损坏或无法打开？

1. 检查「系统设置」➔「隐私与安全性」➔「允许从以下位置下载的应用程序」选择 App Store 与被认可的开发者。
2. 在终端执行以下命令重置属性并重签：
```bash
sudo xattr -r -d com.apple.quarantine /Applications/Clipboard.app
sudo codesign --force --deep --sign - /Applications/Clipboard.app
```

---

## 📄 许可证说明 (License)

本项目遵循 **Creative Commons Attribution-NonCommercial 4.0 International Public License (CC BY-NC 4.0)** 开源协议。
详情请参阅 [LICENSE](LICENSE) 文件。
