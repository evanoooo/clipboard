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

    enclosures_xml = ""
    for enc in enclosures:
        arch_attr = f'\n                sparkle:arch="{enc["arch"]}"' if enc.get("arch") else ""
        enclosures_xml += f"""            <enclosure
                url="https://github.com/{repo}/releases/download/v{version}/{enc['name']}"{arch_attr}
                sparkle:edSignature="{enc['signature']}"
                length="{enc['length']}"
                type="application/octet-stream" />\n"""

    item_xml = f"""        <!-- Version {version} -->
        <item>
            <title>Version {version}</title>
            <description sparkle:format="markdown">
                <![CDATA[
## Version {version}

- 架构增强与底层数据增量同步优化；
- Sparkle 2 自动更新与独立 Ed25519 签名体系；
- 独立提供 Apple Silicon (arm64)、Intel (x86_64) 与 Universal 原生架构安装包；
- 现代化标准化 DMG 与 ZIP 双格式制品分发。
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
