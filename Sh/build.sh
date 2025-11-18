#!/bin/bash

# 构建和打包脚本
# 用于构建应用并生成 DMG 安装包

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

echo -e "${BLUE}╔════════════════════════════════════════╗${NC}"
echo -e "${BLUE}║      应用构建和打包工具                ║${NC}"
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

echo -e "${GREEN}📦 构建配置${NC}"
echo "----------------------------------------"
echo "应用名称: $APP_NAME"
echo "版本号:   $VERSION"
echo "构建号:   $BUILD"
echo "配置:     $CONFIGURATION"
echo ""

# 查找 Xcode 项目
if [ ! -f "$APP_NAME.xcodeproj/project.pbxproj" ]; then
    echo -e "${RED}❌ 错误: 未找到 Xcode 项目${NC}"
    exit 1
fi

# 检查 Xcode 是否可用
XCODE_PATH=$(xcode-select -p 2>/dev/null || echo "")
if [[ "$XCODE_PATH" == *"CommandLineTools"* ]] || [ -z "$XCODE_PATH" ]; then
    echo -e "${YELLOW}⚠️  检测到使用命令行工具,尝试切换到 Xcode.app...${NC}"
    
    # 查找 Xcode.app
    if [ -d "/Applications/Xcode.app" ]; then
        echo "找到 Xcode.app,正在切换..."
        sudo xcode-select -s /Applications/Xcode.app/Contents/Developer
        echo -e "${GREEN}✅ 已切换到 Xcode.app${NC}"
        echo ""
    else
        echo -e "${RED}❌ 错误: 未找到 Xcode.app${NC}"
        echo "请安装 Xcode 或在 Xcode 中手动构建项目"
        exit 1
    fi
fi

# 步骤 1: 清理构建目录
echo -e "${BLUE}🧹 步骤 1/5: 清理构建目录...${NC}"
xcodebuild clean -scheme "$SCHEME" -configuration "$CONFIGURATION" > /dev/null 2>&1 || true
echo -e "${GREEN}✅ 清理完成${NC}"
echo ""

# 步骤 2: 构建应用
echo -e "${BLUE}🔨 步骤 2/5: 构建应用...${NC}"
echo "这可能需要几分钟..."

xcodebuild \
    -scheme "$SCHEME" \
    -configuration "$CONFIGURATION" \
    MARKETING_VERSION="$VERSION" \
    CURRENT_PROJECT_VERSION="$BUILD" \
    clean build | grep -E '^(Build|=|❌|⚠️)' || true

if [ ${PIPESTATUS[0]} -ne 0 ]; then
    echo -e "${RED}❌ 构建失败${NC}"
    exit 1
fi

echo -e "${GREEN}✅ 构建完成${NC}"
echo ""

# 步骤 3: 查找构建产物
echo -e "${BLUE}🔍 步骤 3/5: 查找构建产物...${NC}"

# 查找 DerivedData 中的应用
DERIVED_DATA=$(xcodebuild -scheme "$SCHEME" -configuration "$CONFIGURATION" -showBuildSettings | grep " BUILT_PRODUCTS_DIR" | sed 's/.*= //')

if [ -z "$DERIVED_DATA" ]; then
    echo -e "${RED}❌ 错误: 未找到构建目录${NC}"
    exit 1
fi

APP_PATH="$DERIVED_DATA/$APP_NAME.app"

if [ ! -d "$APP_PATH" ]; then
    echo -e "${RED}❌ 错误: 未找到应用: $APP_PATH${NC}"
    exit 1
fi

echo -e "${GREEN}✅ 找到应用: $APP_PATH${NC}"
echo ""

# 步骤 4: 重新签名应用
echo -e "${BLUE}🔐 步骤 4/5: 重新签名应用...${NC}"

# 移除扩展属性
xattr -cr "$APP_PATH" 2>/dev/null || true

# 检查 entitlements 文件
ENTITLEMENTS_PATH="./Clipboard/Clipboard.entitlements"
if [ -f "$ENTITLEMENTS_PATH" ]; then
    echo "使用 entitlements: $ENTITLEMENTS_PATH"
    codesign --force --deep --sign - \
        --entitlements "$ENTITLEMENTS_PATH" \
        --timestamp=none \
        "$APP_PATH"
else
    echo "未找到 entitlements 文件，使用默认签名"
    codesign --force --deep --sign - "$APP_PATH"
fi

# 验证签名
if codesign --verify --verbose "$APP_PATH" 2>&1; then
    echo -e "${GREEN}✅ 应用签名完成并验证通过${NC}"
else
    echo -e "${YELLOW}⚠️  签名验证警告，但继续执行${NC}"
fi
echo ""

# 步骤 5: 创建 DMG 安装包
echo -e "${BLUE}💿 步骤 5/5: 创建 DMG 安装包...${NC}"

DMG_NAME="$APP_NAME-$VERSION.dmg"
DMG_PATH="./$DMG_NAME"
DMG_TEMP_DIR="./dmg_temp"

# 删除旧文件
rm -f "$DMG_PATH"
rm -rf "$DMG_TEMP_DIR"

# 创建临时目录
mkdir -p "$DMG_TEMP_DIR"

# 复制应用到临时目录
cp -R "$APP_PATH" "$DMG_TEMP_DIR/"

# 创建 Applications 符号链接
ln -s /Applications "$DMG_TEMP_DIR/Applications"

# 创建 DMG
hdiutil create \
    -volname "$APP_NAME $VERSION" \
    -srcfolder "$DMG_TEMP_DIR" \
    -ov \
    -format UDZO \
    "$DMG_PATH"

# 清理临时目录
rm -rf "$DMG_TEMP_DIR"

DMG_SIZE=$(ls -l "$DMG_PATH" | awk '{print $5}')

echo -e "${GREEN}✅ DMG 创建完成: $DMG_NAME${NC}"
echo "   大小: $DMG_SIZE 字节 ($(numfmt --to=iec-i --suffix=B $DMG_SIZE 2>/dev/null || echo 'N/A'))"
echo ""

# 总结
echo -e "${GREEN}✅ 构建完成！${NC}"
echo ""
echo -e "${BLUE}📦 生成的文件:${NC}"
echo "   文件名: $DMG_NAME"
echo "   路径:   $DMG_PATH"
echo "   大小:   $DMG_SIZE 字节 ($(numfmt --to=iec-i --suffix=B $DMG_SIZE 2>/dev/null || echo 'N/A'))"
echo ""
echo -e "${BLUE}📝 下一步:${NC}"
echo "   1. 双击 $DMG_NAME 进行测试"
echo "   2. 上传到 GitHub Releases 供用户下载"
echo "   3. 运行 sign_update.sh 生成 Sparkle 更新包"
echo ""
