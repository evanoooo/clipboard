#!/bin/bash

# Sparkle 更新包签名脚本
# 为已构建的应用生成 Sparkle 更新签名

set -e

# 颜色输出
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# 配置
APP_NAME="Clipboard"
SCHEME="Clipboard"
CONFIGURATION="Release"
PRIVATE_KEY_PATH="$HOME/.sparkle_private_key"

echo -e "${BLUE}╔════════════════════════════════════════╗${NC}"
echo -e "${BLUE}║    Sparkle 更新包签名工具              ║${NC}"
echo -e "${BLUE}╚════════════════════════════════════════╝${NC}"
echo ""

# 检查参数
if [ $# -lt 1 ]; then
    echo -e "${YELLOW}使用方法:${NC}"
    echo "  $0 <版本号> [构建号]"
    echo ""
    echo -e "${YELLOW}示例:${NC}"
    echo "  $0 0.2.1 5"
    echo "  $0 0.3.0"
    echo ""
    exit 1
fi

VERSION=$1
BUILD=${2:-$(date +%s)}

echo -e "${GREEN}📦 签名配置${NC}"
echo "----------------------------------------"
echo "应用名称: $APP_NAME"
echo "版本号:   $VERSION"
echo "构建号:   $BUILD"
echo ""

# 检查私钥
if [ ! -f "$PRIVATE_KEY_PATH" ]; then
    echo -e "${RED}❌ 错误: 未找到私钥文件${NC}"
    echo "请先生成 Sparkle 密钥并保存到: $PRIVATE_KEY_PATH"
    echo ""
    echo "运行以下命令生成密钥:"
    echo "  ./generate_sparkle_keys.sh"
    exit 1
fi

echo -e "${GREEN}✅ 找到私钥文件${NC}"
echo ""

echo -e "${BLUE}🔍 步骤 1/3: 查找构建产物...${NC}"

DERIVED_DATA=$(xcodebuild -scheme "$SCHEME" -destination 'platform=macOS,arch=arm64' -configuration "$CONFIGURATION" -showBuildSettings 2>/dev/null | grep " BUILT_PRODUCTS_DIR" | sed 's/.*= //')

if [ -z "$DERIVED_DATA" ]; then
    echo -e "${RED}❌ 错误: 未找到构建目录${NC}"
    echo "请先运行 ./build.sh $VERSION 构建应用"
    exit 1
fi

APP_PATH="$DERIVED_DATA/$APP_NAME.app"

if [ ! -d "$APP_PATH" ]; then
    echo -e "${RED}❌ 错误: 未找到应用: $APP_PATH${NC}"
    echo "请先运行 ./build.sh $VERSION 构建应用"
    exit 1
fi

echo -e "${GREEN}✅ 找到应用: $APP_PATH${NC}"
echo ""

echo -e "${BLUE}📦 步骤 2/3: 打包 ZIP 更新包...${NC}"

ZIP_NAME="$APP_NAME-$VERSION.zip"
ZIP_PATH="./$ZIP_NAME"

rm -f "$ZIP_PATH"

ditto -c -k --sequesterRsrc --keepParent "$APP_PATH" "$ZIP_PATH"

ZIP_SIZE=$(ls -l "$ZIP_PATH" | awk '{print $5}')

echo -e "${GREEN}✅ ZIP 打包完成: $ZIP_NAME${NC}"
echo "   大小: $ZIP_SIZE 字节 ($(numfmt --to=iec-i --suffix=B $ZIP_SIZE 2>/dev/null || echo 'N/A'))"
echo ""

echo -e "${BLUE}🔐 步骤 3/3: 签名更新包...${NC}"

SIGN_UPDATE_TOOL=""
    
# 在 DerivedData 中查找 Sparkle artifacts
SPARKLE_BIN=$(find ~/Library/Developer/Xcode/DerivedData -path "*/SourcePackages/artifacts/sparkle/Sparkle/bin/sign_update" 2>/dev/null | head -n 1)
    
if [ -n "$SPARKLE_BIN" ] && [ -x "$SPARKLE_BIN" ]; then
        SIGN_UPDATE_TOOL="$SPARKLE_BIN"
    echo -e "${GREEN}✅ 找到 Sparkle artifacts 中的 sign_update${NC}"
    echo "   路径: $SPARKLE_BIN"
else
    echo -e "${RED}❌ 错误: 无法找到签名工具${NC}"
    exit 1  
fi

if [ -n "$SIGN_UPDATE_TOOL" ]; then
    SIGNATURE=$("$SIGN_UPDATE_TOOL" "$ZIP_PATH" -f "$PRIVATE_KEY_PATH" 2>&1)
fi

if [ -z "$SIGNATURE" ]; then
    echo -e "${RED}❌ 签名失败${NC}"
    echo "输出: $SIGNATURE"
    exit 1
fi

ED_SIGNATURE=$(echo "$SIGNATURE" | grep -o 'sparkle:edSignature="[^"]*"' | sed 's/sparkle:edSignature="\([^"]*\)"/\1/')
SIGNATURE_LENGTH=$(echo "$SIGNATURE" | grep -o 'length="[^"]*"' | sed 's/length="\([^"]*\)"/\1/')

if [ -z "$SIGNATURE_LENGTH" ]; then
    SIGNATURE_LENGTH="$ZIP_SIZE"
fi

echo -e "${GREEN}✅ 签名完成${NC}"
echo ""

# 获取 GitHub Release Notes
echo -e "${BLUE}📥 获取 GitHub Release Notes...${NC}"

GITHUB_REPO="Ineffable919/clipboard"
RELEASE_NOTES=""

# 尝试从 GitHub API 获取 Release Notes
GITHUB_API_URL="https://api.github.com/repos/$GITHUB_REPO/releases/tags/v$VERSION"
RELEASE_DATA=$(curl -s "$GITHUB_API_URL" 2>/dev/null || echo "")

if [ -n "$RELEASE_DATA" ] && echo "$RELEASE_DATA" | grep -q "\"body\""; then
    # 提取 Release Notes 内容
    RELEASE_BODY=$(echo "$RELEASE_DATA" | python3 -c "import sys, json; data=json.load(sys.stdin); print(data.get('body', ''))" 2>/dev/null || echo "")
    
    if [ -n "$RELEASE_BODY" ]; then
        # 将 Markdown 转换为 HTML
        RELEASE_NOTES=$(echo "$RELEASE_BODY" | python3 -c "
import sys
import re

md = sys.stdin.read()

# 转换标题
md = re.sub(r'^### (.+)$', r'<h3>\1</h3>', md, flags=re.MULTILINE)
md = re.sub(r'^## (.+)$', r'<h2>\1</h2>', md, flags=re.MULTILINE)
md = re.sub(r'^# (.+)$', r'<h1>\1</h1>', md, flags=re.MULTILINE)

# 转换列表
lines = md.split('\n')
result = []
in_list = False
for line in lines:
    if line.strip().startswith('- ') or line.strip().startswith('* '):
        if not in_list:
            result.append('<ul>')
            in_list = True
        item = line.strip()[2:]
        result.append(f'    <li>{item}</li>')
    else:
        if in_list:
            result.append('</ul>')
            in_list = False
        if line.strip():
            result.append(line)
if in_list:
    result.append('</ul>')

print('\n'.join(result))
" 2>/dev/null || echo "$RELEASE_BODY")
        
        echo -e "${GREEN}✅ 成功获取 Release Notes${NC}"
    else
        echo -e "${YELLOW}⚠️  Release Notes 为空，使用默认内容${NC}"
    fi
else
    echo -e "${YELLOW}⚠️  未找到版本 v$VERSION 的 Release，使用默认内容${NC}"
    echo "   请确保已在 GitHub 上创建对应的 Release"
fi

# 如果没有获取到 Release Notes，使用默认内容
if [ -z "$RELEASE_NOTES" ]; then
    RELEASE_NOTES="<h2>更新内容</h2>
<ul>
    <li>新功能和改进</li>
    <li>修复了一些问题</li>
</ul>"
fi

echo ""
echo -e "${BLUE}📝 生成 appcast 条目...${NC}"
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo -e "${GREEN}📋 将以下内容添加到 appcast.xml:${NC}"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

cat << EOF
    <item>
        <title>Version $VERSION</title>
        <description>
            <![CDATA[
                $RELEASE_NOTES
            ]]>
        </description>
        <pubDate>$(date -R)</pubDate>
        <sparkle:version>$BUILD</sparkle:version>
        <sparkle:shortVersionString>$VERSION</sparkle:shortVersionString>
        <sparkle:minimumSystemVersion>14.0</sparkle:minimumSystemVersion>
        <enclosure 
            url="https://github.com/$GITHUB_REPO/releases/download/v$VERSION/$ZIP_NAME" 
            sparkle:edSignature="$ED_SIGNATURE"
            length="$SIGNATURE_LENGTH"
            type="application/octet-stream" />
    </item>
EOF

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

# 总结
echo -e "${GREEN}✅ 签名完成！${NC}"
echo ""
echo -e "${BLUE}📦 生成的文件:${NC}"
echo "   文件名: $ZIP_NAME"
echo "   路径:   $ZIP_PATH"
echo "   大小:   $SIGNATURE_LENGTH 字节"
echo ""
echo -e "${BLUE}🔐 签名信息:${NC}"
echo "   sparkle:edSignature=\"$ED_SIGNATURE\""
echo "   length=\"$SIGNATURE_LENGTH\""
echo ""
if [ -n "$SIGN_UPDATE_TOOL" ] && [ "$SIGN_UPDATE_TOOL" != "sign_update" ]; then
    echo -e "${BLUE}🔧 使用的签名工具:${NC}"
    echo "   $SIGN_UPDATE_TOOL"
    echo ""
fi
echo -e "${BLUE}📝 下一步:${NC}"
echo "   1. 更新 appcast.xml（复制上面的 <item> 内容）"
echo "   2. 上传 $ZIP_NAME 到 GitHub Releases"
echo ""
