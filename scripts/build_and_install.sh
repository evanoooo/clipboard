#!/bin/bash
#
# build_and_install.sh
# 自动化构建 Clipboard Release 包并热升级覆盖本地 /Applications/Clipboard.app
#

set -euo pipefail

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# 路径常量
PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TARGET_APP_PATH="/Applications/Clipboard.app"
RELEASE_DIR="${PROJECT_ROOT}/release"
SCHEME="Clipboard"
CONFIGURATION="Release"

RUN_TESTS=true
AUTO_LAUNCH=true

# 解析命令行参数
for arg in "$@"; do
    case "$arg" in
        --no-test|--skip-tests)
            RUN_TESTS=false
            shift
            ;;
        --no-launch)
            AUTO_LAUNCH=false
            shift
            ;;
        -h|--help)
            echo -e "${CYAN}用法: $0 [选项]${NC}"
            echo ""
            echo "选项:"
            echo "  --no-test, --skip-tests  跳过 SPM 单元测试门禁"
            echo "  --no-launch              安装完成后不自动启动应用"
            echo "  -h, --help               显示此帮助信息"
            exit 0
            ;;
        *)
            echo -e "${YELLOW}未知选项: $arg，跳过...${NC}"
            ;;
    esac
done

echo -e "${PURPLE}====================================================${NC}"
echo -e "${PURPLE}       Clipboard 自动构建与本地覆盖升级流水线       ${NC}"
echo -e "${PURPLE}====================================================${NC}"
echo -e "工作目录: ${PROJECT_ROOT}"
echo -e "目标安装路径: ${TARGET_APP_PATH}"
echo ""

# 1. 运行自动化单元测试质量门禁
if [ "$RUN_TESTS" = true ]; then
    echo -e "${BLUE}[1/5] 正在执行全套自动化单元测试门禁...${NC}"
    if (cd "${PROJECT_ROOT}/Tests" && swift run > /dev/null 2>&1); then
        echo -e "${GREEN}✓ 全套单元测试通过！${NC}"
    else
        echo -e "${RED}❌ 单元测试失败！终止构建与覆盖，以保障线上质量稳定性。${NC}"
        echo -e "请在终端执行 'cd Tests && swift run' 查看具体报错日志。"
        exit 1
    fi
else
    echo -e "${YELLOW}[1/5] 已跳过单元测试。${NC}"
fi

# 2. Release 编译打包
echo -e "${BLUE}[2/5] 正在构建 ${CONFIGURATION} 生产包 (xcodebuild)...${NC}"
BUILD_LOG=$(mktemp /tmp/clipboard_build_XXXXXX.log)
if xcodebuild -scheme "$SCHEME" -configuration "$CONFIGURATION" build > "$BUILD_LOG" 2>&1; then
    echo -e "${GREEN}✓ Release 编译成功！${NC}"
else
    echo -e "${RED}❌ 编译失败！日志详情如下:${NC}"
    tail -n 30 "$BUILD_LOG"
    exit 1
fi
rm -f "$BUILD_LOG"

# 解析构建产物路径
BUILD_SETTINGS=$(xcodebuild -scheme "$SCHEME" -configuration "$CONFIGURATION" -showBuildSettings)
BUILD_DIR=$(echo "$BUILD_SETTINGS" | grep -m1 "CONFIGURATION_BUILD_DIR =" | awk -F " = " '{print $2}')
SOURCE_APP="${BUILD_DIR}/${SCHEME}.app"

if [ ! -d "$SOURCE_APP" ]; then
    echo -e "${RED}❌ 未能找到构建产物: ${SOURCE_APP}${NC}"
    exit 1
fi

# 同步一份到 release/ 目录供归档分发
mkdir -p "$RELEASE_DIR"
rm -rf "${RELEASE_DIR}/${SCHEME}.app"
cp -R "$SOURCE_APP" "${RELEASE_DIR}/"
echo -e "${GREEN}✓ 产物已归档至 ${RELEASE_DIR}/${SCHEME}.app ($(du -sh "${RELEASE_DIR}/${SCHEME}.app" | cut -f1))${NC}"

# 3. 退出正在运行中的旧进程
echo -e "${BLUE}[3/5] 检查正在运行的 Clipboard 进程...${NC}"
RUNNING_PIDS=$(pgrep -f "${TARGET_APP_PATH}/Contents/MacOS/Clipboard" || true)
if [ -n "$RUNNING_PIDS" ]; then
    echo -e "${YELLOW}发现正在运行的 Clipboard 实例 (PID: ${RUNNING_PIDS})，正在安全关闭...${NC}"
    killall Clipboard 2>/dev/null || true
    
    # 等待进程完全释放资源（至多5秒）
    WAIT_COUNT=0
    while pgrep -f "${TARGET_APP_PATH}/Contents/MacOS/Clipboard" > /dev/null; do
        sleep 0.5
        WAIT_COUNT=$((WAIT_COUNT + 1))
        if [ $WAIT_COUNT -ge 10 ]; then
            echo -e "${YELLOW}进程仍在运行，尝试强制退出...${NC}"
            killall -9 Clipboard 2>/dev/null || true
            break
        fi
    done
    echo -e "${GREEN}✓ 运行中的实例已退出${NC}"
else
    echo -e "未发现运行中的进程，可直接覆盖。"
fi

# 4. 执行本地覆盖升级
echo -e "${BLUE}[4/5] 正在安装覆盖到 ${TARGET_APP_PATH}...${NC}"
rm -rf "$TARGET_APP_PATH"
cp -R "${RELEASE_DIR}/${SCHEME}.app" "/Applications/"
xattr -cr "$TARGET_APP_PATH" 2>/dev/null || true
echo -e "${GREEN}✓ 已成功覆盖至 ${TARGET_APP_PATH}${NC}"

# 5. 重启应用
if [ "$AUTO_LAUNCH" = true ]; then
    echo -e "${BLUE}[5/5] 正在重新拉起应用...${NC}"
    open "$TARGET_APP_PATH"
    sleep 1
    NEW_PID=$(pgrep -f "${TARGET_APP_PATH}/Contents/MacOS/Clipboard" || true)
    if [ -n "$NEW_PID" ]; then
        echo -e "${GREEN}✓ Clipboard 已成功启动 (PID: ${NEW_PID})${NC}"
    else
        echo -e "${YELLOW}已触发启动命令，若未看到菜单栏图标请手动双击 /Applications/Clipboard.app${NC}"
    fi
else
    echo -e "${BLUE}[5/5] 已根据参数跳过自动拉起。${NC}"
fi

echo ""
echo -e "${GREEN}====================================================${NC}"
echo -e "${GREEN}             🎉 本地覆盖升级圆满完成！              ${NC}"
echo -e "${GREEN}====================================================${NC}"
echo -e "版本信息: $(defaults read "${TARGET_APP_PATH}/Contents/Info.plist" CFBundleShortVersionString 2>/dev/null || echo "未知") ($(defaults read "${TARGET_APP_PATH}/Contents/Info.plist" CFBundleVersion 2>/dev/null || echo "未知"))"
echo -e "${CYAN}提示: 若快捷键自动粘贴未触发，请在「系统设置」➜「隐私与安全性」➜「辅助功能」中将 Clipboard 重新勾选一次即可刷新权限。${NC}"
echo ""
