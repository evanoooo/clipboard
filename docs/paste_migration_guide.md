# Paste.app 数据迁移至 Clipboard 指南

本项目提供了开箱即用的数据迁移工具 [`scripts/import_from_paste.py`](../scripts/import_from_paste.py)，支持将 **Paste.app (Wiheads)** 的剪贴板历史记录无缝、安全地导入到 **Clipboard**。

---

## 🛡️ 安全第一原则

- **绝对只读源库**：脚本强制使用 SQLite 只读 URI 模式（`?mode=ro`）连接 Paste 数据库，**绝不修改、删除或污染 Paste.app 的任何原始数据**；
- **环境安全隔离**：脚本强制要求使用 `--dest` 指定目标数据库文件，**严禁直接修改或静默覆盖生产数据库**；
- **分步演练机制**：推荐先导出到临时测试目录验证无误后，再安全替换至生产目录。

---

## 🔍 技术解析与格式兼容

Paste.app 采用 Apple Core Data（底层为 SQLite）存储数据，不同历史版本和不同媒体类型采用了多代不同的压缩及外置存储架构。迁移脚本通过底层深度逆向，实现了 100% 格式还原：

| 数据类型 / 存储协议 | Paste.app 底层存储机制 | Clipboard 还原方案 |
|---|---|---|
| **普通文本 (早期版本)** | raw DEFLATE 压缩的 JSON (`0x01` 标记) | 采用 `zlib.decompress(payload, -15)` 还原并提取 UTF-8 文本 |
| **现代图文 / 富文本** | Apple 专有 **LZFSE** 压缩 bplist (`0x01` + `bvxn`) | 动态加载 macOS 系统原生 `/usr/lib/libcompression.dylib` 解压 |
| **高清大图 / 外部媒体** | Core Data 外部大文件 (`0x02` + UUID) | 自动定位并读取 `.db_SUPPORT/_EXTERNAL_DATA/` 目录中的真实文件 |
| **未压缩格式** | 纯二进制 Plist (`bplist00`) 或标准 JSON | 自动识别文件头并自适应提取 |
| **来源应用 (App)** | `ZAPPLICATIONENTITY` (应用名 / BundleID / 图标) | 完整解析并映射至 Clipboard 的 `App` 表与关联 `app_id` |
| **时间戳校准** | Core Data 纪元（以 2001-01-01 为起点） | 自动加上 `978307200` 秒转换为标准的 Unix 1970 纪元秒级时间戳 |
| **内容排重** | SHA-256 去重 | 匹配 Clipboard 原生 `PasteboardModel.generateUniqueId` 哈希规范 |

---

## 🚀 迁移操作步骤

### 方式一：应用内原生一键迁移（推荐，v2.4.0+ 支持，带 Beta 标识）

自 **v2.4.0** 版本起，Clipboard 内置了原生安全的 Paste 数据迁移弹窗：

1. 打开 **Clipboard 设置** -> **存储**；
2. 在 **“备份与恢复”** 模块中，找到 **“从 Paste.app 迁移历史记录 [Beta]”**，点击 **“开始导入”**；
3. 系统将自动探测默认的 Paste 数据库路径（支持点击“选择其他文件...”浏览备份）；
4. 预检卡片将自动呈现待迁移总条数、来源应用数量、时间跨度及文件大小；
5. 点击 **“开始导入”**，系统在写入前**自动创建当前数据库的完整安全快照备份**，并基于 SHA-256 全自动去重导入，无缝融入历史时间线；
6. 导入完成后自动重序历史时间线并即时刷新界面，安全零风险！

---

### 方式二：命令行离线演练工具（开发者 / 批量处理）

本项目同时提供了命令行工具 [`scripts/import_from_paste.py`](../scripts/import_from_paste.py) 供离线演练或自定义处理：

#### 第一步：抽样测试与逻辑验证（推荐）

在终端中执行以下命令，抽检 50 条记录导出至临时目录，验证数据解析逻辑：

```bash
# 进入项目根目录
cd /path/to/clipboard

# 提取 50 条数据至 /tmp 测试库
python3 scripts/import_from_paste.py --dest "/tmp/paste_test.sqlite3" --limit 50
```

你将看到详细的解析统计与抽样预览：
```text
==================================================
📖 读取源数据库 (只读安全连接): ~/Library/Application Support/Paste/db.sqlite
📁 外部大文件目录: ~/Library/Application Support/Paste/.db_SUPPORT/_EXTERNAL_DATA
🎯 写入目标数据库: /tmp/paste_test.sqlite3
==================================================
✅ 成功映射 223 个来源应用
📦 发现 50 条待迁移记录...
🎉 导入测试完成！结果统计：
• 成功导入入库: 49 条
• 目标数据库: /tmp/paste_test.sqlite3
```

---

### 第二步：全量导出至独立文件

确认无误后，全量导出 Paste 的所有历史记录至独立数据库文件（例如放到“下载”目录）：

```bash
python3 scripts/import_from_paste.py --dest ~/Downloads/Clip_Imported_From_Paste.sqlite3
```

> 💡 **提示**：若你的 Paste.app 数据库路径不是默认位置，可以通过 `--source` 参数自定义指定源文件，例如：
> ```bash
> python3 scripts/import_from_paste.py \
>   --source "/path/to/db.sqlite" \
>   --dest ~/Downloads/Clip_Imported_From_Paste.sqlite3
> ```

---

### 第三步：安全生效至 Clipboard 生产环境

在将导出的数据库投入生产使用前，请遵循安全替换三部曲：

1. **退出应用**：完全退出正在运行的 **Clipboard**；
2. **备份现有库**（重要）：
   ```bash
   mkdir -p ~/Downloads/Clipboard_Backup
   cp -R ~/Library/Application\ Support/com.crown.clipboard ~/Downloads/Clipboard_Backup/
   ```
3. **替换数据库**：
   ```bash
   cp ~/Downloads/Clip_Imported_From_Paste.sqlite3 ~/Library/Application\ Support/com.crown.clipboard/Clip.sqlite3
   # 移除可能存在的旧 WAL 缓存文件
   rm -f ~/Library/Application\ Support/com.crown.clipboard/Clip.sqlite3-wal
   rm -f ~/Library/Application\ Support/com.crown.clipboard/Clip.sqlite3-shm
   ```
4. **重新启动**：打开 **Clipboard**，所有历史剪贴板记录、图片、来源应用及时间戳将完整呈现！
