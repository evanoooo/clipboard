import sys
import re
from email.utils import formatdate

def main():
    if len(sys.argv) < 6:
        print("Usage: update_appcast.py <version> <zip_name> <length> <signature> <repo> [build_version]")
        sys.exit(1)

    version = sys.argv[1]
    zip_name = sys.argv[2]
    length = sys.argv[3]
    signature = sys.argv[4]
    repo = sys.argv[5]
    build_version = sys.argv[6] if len(sys.argv) > 6 else "888"

    pubdate = formatdate(timeval=None, localtime=False, usegmt=True)

    item_xml = f"""        <!-- Version {version} -->
        <item>
            <title>Version {version}</title>
            <description sparkle:format="markdown">
                <![CDATA[
## Version {version}

- 架构增强与底层数据增量同步优化；
- Sparkle 2 自动更新与独立 Ed25519 签名体系；
- 原生 Universal 架构支持（Apple Silicon 与 Intel x86_64）；
- 提供 DMG 与 ZIP 双格式分发。
]]>
            </description>
            <pubDate>{pubdate}</pubDate>
            <sparkle:version>{build_version}</sparkle:version>
            <sparkle:shortVersionString>{version}</sparkle:shortVersionString>
            <sparkle:minimumSystemVersion>14.0</sparkle:minimumSystemVersion>
            <enclosure
                url="https://github.com/{repo}/releases/download/v{version}/{zip_name}"
                sparkle:edSignature="{signature}"
                length="{length}"
                type="application/octet-stream" />
        </item>"""

    with open("appcast.xml", "r", encoding="utf-8") as f:
        content = f.read()

    # If version already exists in appcast, clean up the duplicate item
    pattern = rf"(\s*<!-- Version {re.escape(version)} -->)?\s*<item>[\s\S]*?<sparkle:shortVersionString>{re.escape(version)}</sparkle:shortVersionString>[\s\S]*?</item>"
    content = re.sub(pattern, "", content)

    target_marker = "<language>zh-CN</language>"
    if target_marker in content:
        content = content.replace(target_marker, target_marker + "\n\n" + item_xml, 1)
    elif "<channel>" in content:
        content = content.replace("<channel>", "<channel>\n" + item_xml, 1)

    with open("appcast.xml", "w", encoding="utf-8") as f:
        f.write(content)

    print(f"Successfully added Version {version} ({build_version}) to appcast.xml")

if __name__ == "__main__":
    main()
