#!/usr/bin/env python3
"""
import_from_paste.py

从 Paste.app (Wiheads) 导入历史数据至 Clipboard (Clip.sqlite3)。

核心安全机制：
1. 默认对 Paste.app 数据库采用只读模式 (URI ?mode=ro)，绝不修改源数据；
2. 必须显式指定目标数据库 --dest（防止误伤生产库 ~/Library/Application Support/com.crown.clipboard/Clip.sqlite3）；
3. 遵循 Clipboard 本地存储标准：
   - 自动解析 Paste 多代存储协议（Raw Deflate JSON、LZFSE bplist、未压缩 bplist 以及 .db_SUPPORT 外部大文件）；
   - 自动提取文本、图片、文件 URL、富文本；
   - 自动映射来源应用名称、Bundle ID 及应用图标；
   - 自动生成符合 SHA-256 规范的 unique_id 去重标识。
"""

import os
import sys
import argparse
import sqlite3
import plistlib
import json
import zlib
import base64
import hashlib
import ctypes
from pathlib import Path

# 加载 macOS 原生 libcompression (针对 LZFSE 解压)
try:
    libcomp = ctypes.cdll.LoadLibrary("/usr/lib/libcompression.dylib")
    libcomp.compression_decode_buffer.argtypes = [
        ctypes.c_char_p, ctypes.c_size_t,
        ctypes.c_char_p, ctypes.c_size_t,
        ctypes.c_void_p, ctypes.c_int
    ]
    libcomp.compression_decode_buffer.restype = ctypes.c_size_t
except Exception:
    libcomp = None

# CoreData epoch (2001-01-01) 相对 Unix epoch (1970-01-01) 差值 (秒)
COREDATA_EPOCH_OFFSET = 978307200

def parse_paste_payload(blob, external_dir=None):
    """
    通用解析 Paste.app 的 ZRAWPASTEBOARDITEMS 数据：
    兼容 Paste 历史全版本架构：
    1. 外部大文件 (0x02 + UUID) -> .db_SUPPORT/_EXTERNAL_DATA
    2. 内联 Deflate 压缩 JSON (0x01 + raw deflate)
    3. 内联 LZFSE 压缩 bplist (0x01 + 'bvxn')
    4. 内联未压缩 bplist (0x01 + 'bplist')
    5. 标准 zlib 压缩数据
    """
    if not blob or len(blob) < 2:
        return None

    marker = blob[0]
    payload = blob[1:]

    # 1. 外部大文件引用
    if marker == 0x02 and external_dir:
        try:
            filename = payload.decode("ascii", errors="ignore").strip()
            ext_path = Path(external_dir) / filename
            if ext_path.exists():
                data = ext_path.read_bytes()
                if data.startswith(b"bplist"):
                    return plistlib.loads(data)
                elif data.startswith(b"[") or data.startswith(b"{"):
                    return json.loads(data)
        except Exception:
            pass

    # 2. 内联数据
    if marker == 0x01:
        # A) 尝试 raw DEFLATE (Paste 早期及部分文本版本的格式)
        try:
            dec = zlib.decompress(payload, -zlib.MAX_WBITS)
            if dec.startswith(b"[") or dec.startswith(b"{"):
                return json.loads(dec)
            elif dec.startswith(b"bplist"):
                return plistlib.loads(dec)
        except Exception:
            pass

        # B) 尝试标准 zlib
        try:
            dec = zlib.decompress(payload)
            if dec.startswith(b"[") or dec.startswith(b"{"):
                return json.loads(dec)
            elif dec.startswith(b"bplist"):
                return plistlib.loads(dec)
        except Exception:
            pass

        # C) 尝试 LZFSE (Apple 专有算法，Paste 现代大图与富文本格式)
        if payload.startswith(b"bvxn") and libcomp:
            for factor in [30, 80, 150]:
                dst_size = len(payload) * factor + 1048576
                dst = ctypes.create_string_buffer(dst_size)
                res = libcomp.compression_decode_buffer(dst, dst_size, payload, len(payload), None, 0x801)
                if res > 0:
                    dec = dst.raw[:res]
                    if dec.startswith(b"bplist"):
                        try: return plistlib.loads(dec)
                        except: pass
                    elif dec.startswith(b"[") or dec.startswith(b"{"):
                        try: return json.loads(dec)
                        except: pass
                    break

        # D) 尝试未压缩 bplist
        if payload.startswith(b"bplist"):
            try: return plistlib.loads(payload)
            except Exception: pass

        # E) 尝试纯 JSON
        if payload.startswith(b"[") or payload.startswith(b"{"):
            try: return json.loads(payload)
            except Exception: pass

    return None

def compute_unique_id(type_name, data):
    """严格匹配 Clipboard 原生 PasteboardModel.generateUniqueId 算法"""
    if type_name in ("public.png", "public.tiff", "public.jpeg"):
        prefix = data[:1024]
        return f"{hashlib.sha256(prefix).hexdigest()}-{len(data)}"
    return hashlib.sha256(data).hexdigest()

def init_clipboard_database(conn):
    """初始化 Clipboard 完整数据库表与索引结构"""
    conn.execute("""
    CREATE TABLE IF NOT EXISTS App (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        bundle_id TEXT,
        app_name TEXT NOT NULL,
        app_path TEXT NOT NULL,
        icon_data BLOB
    );
    """)
    conn.execute("CREATE UNIQUE INDEX IF NOT EXISTS idx_app_bundle ON App(bundle_id) WHERE bundle_id IS NOT NULL;")
    conn.execute("CREATE INDEX IF NOT EXISTS idx_app_path ON App(app_path, app_name);")

    conn.execute("""
    CREATE TABLE IF NOT EXISTS Clip (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        unique_id TEXT NOT NULL,
        type TEXT NOT NULL,
        data BLOB NOT NULL,
        show_data BLOB,
        timestamp INTEGER NOT NULL,
        sort_order INTEGER DEFAULT 0,
        app_id INTEGER NOT NULL,
        search_text TEXT NOT NULL,
        length INTEGER NOT NULL,
        "group" INTEGER DEFAULT -1,
        tag TEXT,
        alias TEXT,
        alias_search TEXT,
        hidden INTEGER DEFAULT 0
    );
    """)
    conn.execute("CREATE UNIQUE INDEX IF NOT EXISTS uidx_unique_id ON Clip(unique_id);")
    conn.execute("CREATE INDEX IF NOT EXISTS idx_sort_order ON Clip(sort_order DESC, id DESC);")
    conn.execute("CREATE INDEX IF NOT EXISTS idx_hidden_order ON Clip(hidden, sort_order DESC, id DESC);")

def import_paste_data(source_db_path, dest_db_path, limit=None):
    source_db_path = os.path.expanduser(source_db_path)
    dest_db_path = os.path.expanduser(dest_db_path)

    if not os.path.exists(source_db_path):
        print(f"❌ 找不到源数据库: {source_db_path}")
        return False

    external_dir = Path(source_db_path).parent / ".db_SUPPORT" / "_EXTERNAL_DATA"
    if not external_dir.exists():
        external_dir = None

    print(f"==================================================")
    print(f"📖 读取源数据库 (只读安全连接): {source_db_path}")
    print(f"📁 外部大文件目录: {external_dir or '无'}")
    print(f"🎯 写入目标数据库: {dest_db_path}")
    print(f"==================================================")

    os.makedirs(os.path.dirname(dest_db_path), exist_ok=True)

    src_uri = f"file:{os.path.abspath(source_db_path)}?mode=ro"
    src_conn = sqlite3.connect(src_uri, uri=True)
    src_conn.row_factory = sqlite3.Row

    dest_conn = sqlite3.connect(dest_db_path)
    init_clipboard_database(dest_conn)

    # 1. 迁移来源应用字典 (ZAPPLICATIONENTITY -> App)
    app_id_mapping = {}
    src_cursor = src_conn.cursor()
    src_cursor.execute("SELECT Z_PK, ZNAME, ZBUNDLEIDENTIFIER, ZRAWICON FROM ZAPPLICATIONENTITY")
    for row in src_cursor.fetchall():
        pk = row["Z_PK"]
        name = row["ZNAME"] or "Unknown"
        bundle_id = row["ZBUNDLEIDENTIFIER"]
        icon_data = row["ZRAWICON"]
        app_path = f"/Applications/{name}.app"

        if bundle_id:
            cur = dest_conn.execute("SELECT id FROM App WHERE bundle_id = ?", (bundle_id,)).fetchone()
        else:
            cur = dest_conn.execute("SELECT id FROM App WHERE app_name = ?", (name,)).fetchone()

        if cur:
            app_id_mapping[pk] = cur[0]
        else:
            ins = dest_conn.execute(
                "INSERT INTO App (bundle_id, app_name, app_path, icon_data) VALUES (?, ?, ?, ?)",
                (bundle_id, name, app_path, icon_data)
            )
            app_id_mapping[pk] = ins.lastrowid

    # 兜底应用
    fallback_app_cur = dest_conn.execute("SELECT id FROM App WHERE bundle_id = 'com.apple.finder'").fetchone()
    if fallback_app_cur:
        fallback_app_id = fallback_app_cur[0]
    else:
        fallback_app_id = dest_conn.execute(
            "INSERT INTO App (bundle_id, app_name, app_path) VALUES ('com.apple.finder', 'Finder', '/System/Library/CoreServices/Finder.app')"
        ).lastrowid

    dest_conn.commit()
    print(f"✅ 成功映射 {len(app_id_mapping)} 个来源应用")

    # 2. 批量读取剪贴板条目
    query = """
    SELECT i.Z_PK, i.ZRAWTYPE, i.ZSOURCEAPPLICATION, i.ZCREATEDAT, i.ZTITLE,
           d.ZRAWPASTEBOARDITEMS
    FROM ZITEMENTITY i
    LEFT JOIN ZITEMDATAENTITY d ON i.ZDATA = d.Z_PK
    WHERE d.ZRAWPASTEBOARDITEMS IS NOT NULL
    ORDER BY i.Z_PK ASC
    """
    if limit:
        query += f" LIMIT {int(limit)}"

    src_cursor.execute(query)
    rows = src_cursor.fetchall()
    print(f"📦 发现 {len(rows)} 条待迁移记录...")

    imported_count = 0
    skipped_count = 0
    duplicate_count = 0
    type_stats = {"text": 0, "image": 0, "file": 0, "other": 0}

    sort_order = dest_conn.execute("SELECT COALESCE(MAX(sort_order), 0) FROM Clip").fetchone()[0]

    dest_conn.execute("BEGIN TRANSACTION;")

    for row in rows:
        raw_created_at = row["ZCREATEDAT"]
        timestamp = int(raw_created_at + COREDATA_EPOCH_OFFSET) if raw_created_at else 0
        app_id = app_id_mapping.get(row["ZSOURCEAPPLICATION"], fallback_app_id)
        blob = row["ZRAWPASTEBOARDITEMS"]

        parsed = parse_paste_payload(blob, external_dir)
        if not parsed:
            skipped_count += 1
            continue

        # 兼容 list[dict] 或 dict 结构
        if isinstance(parsed, list) and parsed:
            item_dict = parsed[0]
        elif isinstance(parsed, dict):
            item_dict = parsed
        else:
            skipped_count += 1
            continue

        raw_data_map = item_dict.get("dataByType", {})
        if not raw_data_map:
            skipped_count += 1
            continue

        # 将可能包含 base64 字符串的映射统一转化为 bytes
        data_by_type = {}
        for uti, val in raw_data_map.items():
            if isinstance(val, bytes):
                data_by_type[uti] = val
            elif isinstance(val, str):
                try:
                    data_by_type[uti] = base64.b64decode(val)
                except Exception:
                    data_by_type[uti] = val.encode("utf-8")

        clip_type = None
        clip_data = None
        search_text = ""
        length = 0

        # 1. 优先文本
        if "public.utf8-plain-text" in data_by_type:
            clip_type = "public.utf8-plain-text"
            clip_data = data_by_type["public.utf8-plain-text"]
            try: search_text = clip_data.decode("utf-8", errors="replace")
            except Exception: search_text = ""
            length = len(search_text)
            type_stats["text"] += 1
        elif "public.text" in data_by_type:
            clip_type = "public.utf8-plain-text"
            clip_data = data_by_type["public.text"]
            try: search_text = clip_data.decode("utf-8", errors="replace")
            except Exception: search_text = ""
            length = len(search_text)
            type_stats["text"] += 1
        # 2. 富文本
        elif "public.rtf" in data_by_type:
            clip_type = "public.rtf"
            clip_data = data_by_type["public.rtf"]
            search_text = row["ZTITLE"] or ""
            length = len(search_text)
            type_stats["text"] += 1
        # 3. 图片
        elif "public.png" in data_by_type:
            clip_type = "public.png"
            clip_data = data_by_type["public.png"]
            search_text = row["ZTITLE"] or "图片"
            length = len(clip_data)
            type_stats["image"] += 1
        elif "public.tiff" in data_by_type:
            clip_type = "public.tiff"
            clip_data = data_by_type["public.tiff"]
            search_text = row["ZTITLE"] or "图片"
            length = len(clip_data)
            type_stats["image"] += 1
        elif "public.jpeg" in data_by_type:
            clip_type = "public.png"
            clip_data = data_by_type["public.jpeg"]
            search_text = row["ZTITLE"] or "图片"
            length = len(clip_data)
            type_stats["image"] += 1
        # 4. 文件
        elif "public.file-url" in data_by_type:
            clip_type = "public.file-url"
            clip_data = data_by_type["public.file-url"]
            try: search_text = clip_data.decode("utf-8", errors="replace")
            except Exception: search_text = "文件"
            length = len(search_text)
            type_stats["file"] += 1
        # 5. 其他类型兜底
        else:
            first_uti = list(data_by_type.keys())[0]
            clip_type = first_uti
            clip_data = data_by_type[first_uti]
            search_text = row["ZTITLE"] or first_uti
            length = len(clip_data)
            type_stats["other"] += 1

        if not clip_data:
            skipped_count += 1
            continue

        sort_order += 1
        unique_id = compute_unique_id(clip_type, clip_data)

        # 检查是否已存在 (基于 unique_id 去重)
        exist_check = dest_conn.execute("SELECT id FROM Clip WHERE unique_id = ?", (unique_id,)).fetchone()
        if exist_check:
            duplicate_count += 1
            continue

        dest_conn.execute("""
        INSERT INTO Clip
        (unique_id, type, data, show_data, timestamp, sort_order, app_id, search_text, length, "group", tag, alias, alias_search, hidden)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, -1, NULL, NULL, NULL, 0)
        """, (unique_id, clip_type, clip_data, None, timestamp, sort_order, app_id, search_text, length))
        imported_count += 1

    dest_conn.commit()

    print("\n" + "=" * 55)
    print(f"🎉 导入测试完成！结果统计：")
    print(f"• 成功导入入库: {imported_count} 条")
    print(f"• 识别重复忽略: {duplicate_count} 条")
    print(f"• 格式损坏跳过: {skipped_count} 条")
    print(f"• 分类类型分布: 文本 {type_stats['text']} | 图片 {type_stats['image']} | 文件 {type_stats['file']} | 其他 {type_stats['other']}")
    print(f"• 测试数据库文件: {dest_db_path}")
    print("=" * 55)

    # 抽检验证
    sample_rows = dest_conn.execute("""
    SELECT c.id, c.type, c.search_text, c.timestamp, a.app_name
    FROM Clip c
    LEFT JOIN App a ON c.app_id = a.id
    ORDER BY c.id DESC LIMIT 5
    """).fetchall()

    print("\n🔍 抽检最新入库 5 条数据：")
    for r in sample_rows:
        text_preview = r[2][:35].replace("\n", " ") if r[2] else ""
        print(f"  ID={r[0]} | Type={r[1]} | App={r[4]} | Text='{text_preview}' | Time={r[3]}")

    dest_conn.close()
    src_conn.close()
    return True

if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="从 Paste.app 安全导入历史数据至 Clipboard")
    parser.add_argument("--source", default="~/Library/Application Support/Paste/db.sqlite", help="Paste.app SQLite 数据库路径")
    parser.add_argument("--dest", required=True, help="目标数据库路径（测试时务必指定为临时目录）")
    parser.add_argument("--limit", type=int, default=None, help="导入条数上限（用于逻辑快速验证）")

    args = parser.parse_args()
    import_paste_data(args.source, args.dest, args.limit)
