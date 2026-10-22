<p align="center">
    <div align="center"><img src=Clipboard/Resource/Assets.xcassets/AppIcon.appiconset/icon-256.png width=135  /></div>
    <h2 align="center">Clipboard</h2>
    <div align="center">A modern, ultra-fast, and battery-efficient clipboard manager for macOS.</div>
    <div align="center"><strong>English</strong> | <a href="https://github.com/Ineffable919/clipboard/blob/master/README_ZH.md">中文</a></div>
</p>

<img src="examples.png">

## 📥 Download

Download the latest version from [releases](https://github.com/Ineffable919/clipboard/releases/latest)

---

## ✨ Features & Latest Enhancements

- ⚡️ **Sub-millisecond Performance & Low Footprint**:
  - Engineered with 4 composite covering indexes to eliminate table scans, maintaining query latencies at ~0.2ms across 10,000+ records.
  - Zero-allocation runtime LRU cache for attributed strings and syntax highlighting; code cards highlight once and scroll smoothly at 120 FPS.
  - Near-zero battery drain with 0.0% background idle CPU usage.
- 🏷️ **Drag-to-Reorder Category Chips (New)**:
  - Custom category chips support smooth horizontal drag gestures with native haptic feedback and fluid collision snapping animations (Safari/Chrome tab feel).
  - Built-in "Clipboard" item and "+" creation button are guarded and fixed; reordered tabs synchronize globally across the main window, floating window, and menus.
- 🎨 **Modernized Card Header & Rich Metadata (New)**:
  - Resolved source app icon loss when pinning or categorizing clips—app icons are always preserved.
  - Focused single-line aliases when custom titles are provided.
  - Bottom metadata upgraded with SF Symbols vector icons, language detectors, and character metrics (e.g. `Java · 48 chars`).
- 📋 **Full-Format Smart Capture**:
  - Automatically captures and formats plain text, rich text, multi-line code, images, color hexes, and file streams.
  - Built-in ephemeral content and password manager exclusion (1Password, Keychain, etc.).
- 🔍 **Multi-dimensional Search & FTS5**:
  - Quickly filter clips by type (images, code, links, files), date ranges, source apps, and custom tags.
- 🪟 **Floating Window & Quick Actions**:
  - Double-click to paste directly, Enter to paste, `Shift + Enter` to paste as plain text.
  - Spacebar for instant high-fidelity preview with multi-line JSON formatting and editing.
  - Drag and drop cards into third-party apps or onto tags to categorize.
- 🛡️ **Safe & Private**:
  - Confirmation prompt for deletions, configurable retention periods, and 100% local persistence with zero telemetry.

---

## 💻 System Requirements

- macOS 14.0 or later (Fully compatible with macOS Sonoma, Sequoia, and later)
- Supports Apple Silicon (arm64) and Intel (x86_64) architectures

---

## 🛠️ Build & Tests

Automated test runner and hot-upgrade script included:

```bash
# 1. Run all 281 automated unit tests
cd Tests && swift run

# 2. Build Release package and hot-replace running app
./scripts/build_and_install.sh
```

---

## ⌨️ Keyboard Shortcuts

- `ESC`: Close window / cancel editing
- `←` `→`: Navigate history records
- `Space`: Preview selected item
- `↩`: Paste selected item
- `Shift + ↩`: Paste as plain text
- `⌘ + C`: Copy selected item to clipboard
- `Delete`: Delete selected item

---

## ❓ FAQ

### App damaged or can't be opened?

1. Go to System Settings -> Privacy & Security -> Allow applications downloaded from App Store and identified developers.
2. In terminal, run:
```bash
sudo xattr -r -d com.apple.quarantine /Applications/Clipboard.app
sudo codesign --force --deep --sign - /Applications/Clipboard.app
```

---

## 📄 License

This project is licensed under the **Creative Commons Attribution-NonCommercial 4.0 International Public License (CC BY-NC 4.0)**. See the [LICENSE](LICENSE) file for details.
