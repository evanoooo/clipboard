import sys
import datetime
from email.utils import formatdate

def main():
    if len(sys.argv) < 6:
        print("Usage: update_appcast.py <version> <zip_name> <length> <signature> <repo>")
        sys.exit(1)

    version = sys.argv[1]
    zip_name = sys.argv[2]
    length = sys.argv[3]
    signature = sys.argv[4]
    repo = sys.argv[5]

    pubdate = formatdate(timeval=None, localtime=False, usegmt=True)

    item_xml = f"""        <item>
            <title>Version {version}</title>
            <pubDate>{pubdate}</pubDate>
            <sparkle:shortVersionString>{version}</sparkle:shortVersionString>
            <sparkle:minimumSystemVersion>14.0</sparkle:minimumSystemVersion>
            <enclosure
                url="https://github.com/{repo}/releases/download/v{version}/{zip_name}"
                sparkle:arch="arm64"
                sparkle:edSignature="{signature}"
                length="{length}"
                type="application/octet-stream" />
        </item>"""

    with open("appcast.xml", "r", encoding="utf-8") as f:
        content = f.read()

    if "<channel>" in content:
        content = content.replace("<channel>", "<channel>\n" + item_xml, 1)

    with open("appcast.xml", "w", encoding="utf-8") as f:
        f.write(content)

    print(f"Successfully added Version {version} to appcast.xml")

if __name__ == "__main__":
    main()
