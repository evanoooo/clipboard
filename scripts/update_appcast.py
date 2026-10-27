import sys
import re
import json
from email.utils import formatdate

def main():
    if len(sys.argv) < 2:
        print("Usage:")
        print("  update_appcast.py <version> <repo> <build_version> <enclosures_json>")
        print("  update_appcast.py <version> <zip_name> <length> <signature> <repo> [build_version]")
        sys.exit(1)

    version = sys.argv[1]
    
    # Check if using the JSON format:
    if len(sys.argv) >= 5 and (sys.argv[4].startswith("[") or sys.argv[4].startswith("{")):
        repo = sys.argv[2]
        build_version = sys.argv[3]
        enclosures_data = json.loads(sys.argv[4])
        if isinstance(enclosures_data, dict):
            enclosures = [enclosures_data]
        else:
            enclosures = enclosures_data
    elif len(sys.argv) >= 6:
        zip_name = sys.argv[2]
        length = sys.argv[3]
        signature = sys.argv[4]
        repo = sys.argv[5]
        build_version = sys.argv[6] if len(sys.argv) > 6 else "888"
        enclosures = [{
            "name": zip_name,
            "length": length,
            "signature": signature
        }]
    else:
        print("Invalid arguments")
        sys.exit(1)

    pubdate = formatdate(timeval=None, localtime=False, usegmt=True)

    if version == "2.4.4":
        release_notes = """## Version 2.4.4

- 修复网页链接中文件下载 URL 预览触发自动下载的问题，限制仅对简单网页展示 Web 预览；
- 针对常见下载文件及带 Query 参数的下载链接，在预览中直接展示文本视图，杜绝异常下载与内存占用；
- WebKit 运行时增加对附件响应、非网页 MIME 类型与下载行为的多重拦截防护；
- 优化卡片与浮动窗口对下载文件的元数据请求，避免大文件不必要的网络开销；
- CI 构建流程支持自签名证书导入签名，保障本地 Sparkle 更新与系统权限继承。"""
    elif version == "2.4.3":
        release_notes = """## Version 2.4.3

- 修复编辑窗口保存任务取消时状态锁死导致无法二次保存的问题；
- 优化图片卡片内存占用，入库生成 300px 压缩缩略图，滚动卡片内存开销骤降 80% 以上；
- 预编译代码高亮 166 个正则模式并完全下沉后台并发任务，彻底消除列表滚动掉帧；
- 修复云端同步恢复长文本截断、增量更新字段丢失与本地删除被云端下回的数据一致性缺陷；
- 建立 CancellableLoadable 强类型协议，消除列表滚动复用时孤儿任务泄露与野指针隐患；
- SQLite 点查增加 SQLITE_TRANSIENT 指针安全与并发 busy timeout 保障；
- 全面升级 Swift 6 并发安全架构，采用 OSAllocatedUnfairLock 替代旧式 GCD 并发屏障。"""
    elif version == "2.4.2":
        release_notes = """## Version 2.4.2

- 重构云端同步调度机制，新增「自动同步策略与频率」多档选择（关闭、实时变动15秒防抖、5分钟~6小时周期同步）；
- 解除 PasteboardWritingItem 与 PasteboardModel 强引用循环，彻底消除卡片拖拽后的内存泄漏；
- 实现拖拽数据惰性按需访问，拖拽起始无需全量加载数十兆大图，显著降低瞬时内存峰值；
- 修复 CollectionViewItem 复用池残留历史数据引用的生命周期问题；
- 将 OCR 识别大图解码流程完全下沉至后台并发任务，彻底消除复制高分辨率图片时的主线程掉帧；
- 优化剪贴板自适应轮询与定时器能耗机制，支持系统内核唤醒批处理，显著提升 MacBook 电池续航。"""
    elif version == "2.4.1":
        release_notes = """## Version 2.4.1

- 完善文档演示体系与多模块视觉画廊；
- 优化多架构打包重签名流水线，确保 Sparkle 升级完全自洽无阻；
- 持续增强 Paste.app 历史数据迁移 (Beta) 健壮性与去重排序算法。"""
    elif version == "2.4.0":
        release_notes = """## Version 2.4.0

- 新增 Paste.app 剪贴板历史数据一键迁移功能 (Beta)；
- 支持自动扫描与手动选取 Paste 本地数据库，全版本兼容（LZFSE / Raw Deflate / bplist / 外部大文件）；
- 严格基于 SHA-256 指纹智能去重，自动保护已有分组、标签与别名；
- 采用真实时间线重序算法，历史记录无缝融入而不干扰最新记录；
- 迁移修改前自动创建本地完整数据库快照备份，安全零风险。"""
    else:
        release_notes = f"""## Version {version}

- 架构增强与底层数据增量同步优化；
- Sparkle 2 自动更新与独立 Ed25519 签名体系；
- 独立提供 Apple Silicon (arm64)、Intel (x86_64) 与 Universal 原生架构安装包；
- 现代化标准化 DMG 与 ZIP 双格式制品分发。"""

    # Check if multiple architecture enclosures are provided
    arm_enc = next((e for e in enclosures if e.get("arch") == "arm64" or "-arm64" in e.get("name", "")), None)
    x86_enc = next((e for e in enclosures if e.get("arch") == "x86_64" or "-x86_64" in e.get("name", "")), None)
    uni_enc = next((e for e in enclosures if not e.get("arch") and ("-universal" in e.get("name", "") or "universal" in e.get("name", ""))), None)

    if arm_enc and (x86_enc or uni_enc):
        # Generate separate items: Apple Silicon first with hardwareRequirements, then Intel/Universal
        items_list = []
        items_list.append(f"""        <!-- Version {version} (Apple Silicon) -->
        <item>
            <title>Version {version} (Apple Silicon)</title>
            <description sparkle:format="markdown">
                <![CDATA[
{release_notes}
]]>
            </description>
            <pubDate>{pubdate}</pubDate>
            <sparkle:version>{build_version}</sparkle:version>
            <sparkle:shortVersionString>{version}</sparkle:shortVersionString>
            <sparkle:minimumSystemVersion>14.0</sparkle:minimumSystemVersion>
            <sparkle:hardwareRequirements>arm64</sparkle:hardwareRequirements>
            <enclosure
                url="https://github.com/{repo}/releases/download/v{version}/{arm_enc['name']}"
                sparkle:edSignature="{arm_enc['signature']}"
                length="{arm_enc['length']}"
                type="application/octet-stream" />
        </item>""")

        fallback_enc = x86_enc or uni_enc
        arch_title = "Intel" if fallback_enc == x86_enc else "Universal"
        items_list.append(f"""        <!-- Version {version} ({arch_title}) -->
        <item>
            <title>Version {version} ({arch_title})</title>
            <description sparkle:format="markdown">
                <![CDATA[
{release_notes}
]]>
            </description>
            <pubDate>{pubdate}</pubDate>
            <sparkle:version>{build_version}</sparkle:version>
            <sparkle:shortVersionString>{version}</sparkle:shortVersionString>
            <sparkle:minimumSystemVersion>14.0</sparkle:minimumSystemVersion>
            <enclosure
                url="https://github.com/{repo}/releases/download/v{version}/{fallback_enc['name']}"
                sparkle:edSignature="{fallback_enc['signature']}"
                length="{fallback_enc['length']}"
                type="application/octet-stream" />
        </item>""")
        item_xml = "\n\n".join(items_list)
    else:
        enclosures_xml = ""
        for enc in enclosures:
            enclosures_xml += f"""            <enclosure
                url="https://github.com/{repo}/releases/download/v{version}/{enc['name']}"
                sparkle:edSignature="{enc['signature']}"
                length="{enc['length']}"
                type="application/octet-stream" />\n"""

        item_xml = f"""        <!-- Version {version} -->
        <item>
            <title>Version {version}</title>
            <description sparkle:format="markdown">
                <![CDATA[
{release_notes}
]]>
            </description>
            <pubDate>{pubdate}</pubDate>
            <sparkle:version>{build_version}</sparkle:version>
            <sparkle:shortVersionString>{version}</sparkle:shortVersionString>
            <sparkle:minimumSystemVersion>14.0</sparkle:minimumSystemVersion>
{enclosures_xml.rstrip()}
        </item>"""

    with open("appcast.xml", "r", encoding="utf-8") as f:
        content = f.read()

    # Clean up existing version entry if any
    pattern = rf"(\s*<!-- Version {re.escape(version)} -->)?\s*<item>[\s\S]*?<sparkle:shortVersionString>{re.escape(version)}</sparkle:shortVersionString>[\s\S]*?</item>"
    content = re.sub(pattern, "", content)

    target_marker = "<language>zh-CN</language>"
    if target_marker in content:
        content = content.replace(target_marker, target_marker + "\n\n" + item_xml, 1)
    elif "<channel>" in content:
        content = content.replace("<channel>", "<channel>\n" + item_xml, 1)

    with open("appcast.xml", "w", encoding="utf-8") as f:
        f.write(content)

    print(f"Successfully updated appcast.xml for Version {version} ({build_version}) with {len(enclosures)} enclosures")

if __name__ == "__main__":
    main()
