#!/bin/bash
# Flutter Skill 一键安装脚本
# 支持 macOS 和 Linux

set -e

# 颜色
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m' # No Color

echo -e "${BLUE}🚀 Flutter Skill 一键安装${NC}"
echo ""

# 检测操作系统
OS="$(uname -s)"
case "${OS}" in
    Linux*)     MACHINE=Linux;;
    Darwin*)    MACHINE=Mac;;
    *)          MACHINE="UNKNOWN:${OS}"
esac

if [ "$MACHINE" = "UNKNOWN:${OS}" ]; then
    echo -e "${RED}❌ 不支持的操作系统: ${OS}${NC}"
    exit 1
fi

# 检测安装方法
echo -e "${YELLOW}检测最佳安装方法...${NC}"
echo ""

# 方法 1: npm (推荐 - 预编译二进制，启动最快)
if command -v npm &> /dev/null; then
    echo -e "${GREEN}✅ 检测到 npm，使用 npm 安装（推荐）${NC}"
    echo ""

    # 检查是否已安装
    if command -v flutter-skill &> /dev/null || command -v flutter-skill-mcp &> /dev/null; then
        echo -e "${YELLOW}⚠️  flutter-skill 已安装，执行更新...${NC}"
        echo "执行: npm install -g flutter-skill-mcp --force"
        npm install -g flutter-skill-mcp --force
    else
        echo "执行: npm install -g flutter-skill-mcp"
        npm install -g flutter-skill-mcp
    fi

    echo ""
    echo -e "${GREEN}✅ 安装成功！${NC}"
    echo ""
    echo "验证安装:"
    flutter-skill --version 2>/dev/null || flutter-skill-mcp --version 2>/dev/null || echo "flutter-skill 命令已安装"

    # 安装工具优先级规则
    echo ""
    echo -e "${YELLOW}📝 安装 Claude Code 工具优先级规则...${NC}"
    if command -v flutter-skill &> /dev/null; then
        flutter-skill setup --silent 2>/dev/null || echo "工具优先级规则安装完成"
    elif command -v flutter-skill-mcp &> /dev/null; then
        flutter-skill-mcp setup --silent 2>/dev/null || echo "工具优先级规则安装完成"
    fi

    echo ""
    echo -e "${GREEN}🎉 安装完成！${NC}"
    exit 0
fi

# 方法 2: Homebrew (macOS/Linux)
if [ "$MACHINE" = "Mac" ] && command -v brew &> /dev/null; then
    echo -e "${GREEN}✅ 检测到 Homebrew，使用 brew 安装${NC}"
    echo ""
    echo "执行: brew tap ai-dashboad/flutter-skill && brew install flutter-skill"
    brew tap ai-dashboad/flutter-skill
    brew install flutter-skill

    echo ""
    echo -e "${GREEN}✅ 安装成功！${NC}"
    echo ""
    echo "验证安装:"
    flutter-skill --version

    # 安装工具优先级规则
    echo ""
    echo -e "${YELLOW}📝 安装 Claude Code 工具优先级规则...${NC}"
    flutter-skill setup --silent || echo "工具优先级规则安装完成"

    echo ""
    echo -e "${GREEN}🎉 安装完成！${NC}"
    exit 0
fi

# 方法 3: 从源码安装（需要 Dart/Flutter）
if command -v dart &> /dev/null || command -v flutter &> /dev/null; then
    echo -e "${YELLOW}⚠️  未检测到 npm 或 Homebrew${NC}"
    echo -e "${YELLOW}使用 Dart 从源码安装（需要 Flutter SDK）${NC}"
    echo ""

    # 检测 Flutter
    if ! command -v flutter &> /dev/null; then
        echo -e "${RED}❌ 错误: 未找到 Flutter SDK${NC}"
        echo ""
        echo "请先安装 Flutter: https://flutter.dev/docs/get-started/install"
        echo ""
        echo "或者使用以下方法之一:"
        echo "  • npm install -g flutter-skill-mcp  (推荐)"
        echo "  • brew install flutter-skill        (macOS)"
        exit 1
    fi

    # 下载源码（如果需要）
    INSTALL_DIR="$HOME/.flutter-skill-src"

    if [ ! -d "$INSTALL_DIR" ]; then
        echo "克隆仓库到 $INSTALL_DIR ..."
        git clone https://github.com/ai-dashboad/flutter-skill.git "$INSTALL_DIR"
    else
        echo "更新源码..."
        cd "$INSTALL_DIR"
        git pull origin main
    fi

    cd "$INSTALL_DIR"

    # 安装依赖
    echo "安装依赖..."
    flutter pub get

    # 创建包装脚本
    echo "创建可执行文件..."
    mkdir -p "$HOME/bin"

    cat > "$HOME/bin/flutter-skill" << 'WRAPPER_EOF'
#!/bin/bash
FLUTTER_SKILL_DIR="$HOME/.flutter-skill-src"
cd "$FLUTTER_SKILL_DIR"
dart run bin/flutter_skill.dart "$@"
WRAPPER_EOF

    chmod +x "$HOME/bin/flutter-skill"

    # 添加到 PATH
    SHELL_RC=""
    if [ -n "$ZSH_VERSION" ] || [ -f "$HOME/.zshrc" ]; then
        SHELL_RC="$HOME/.zshrc"
    elif [ -n "$BASH_VERSION" ] || [ -f "$HOME/.bashrc" ]; then
        SHELL_RC="$HOME/.bashrc"
    elif [ -f "$HOME/.bash_profile" ]; then
        SHELL_RC="$HOME/.bash_profile"
    fi

    if [ -n "$SHELL_RC" ]; then
        if ! grep -q 'export PATH="$HOME/bin:$PATH"' "$SHELL_RC"; then
            echo "" >> "$SHELL_RC"
            echo '# Flutter Skill' >> "$SHELL_RC"
            echo 'export PATH="$HOME/bin:$PATH"' >> "$SHELL_RC"
            echo ""
            echo -e "${GREEN}✅ 已添加到 PATH: $SHELL_RC${NC}"
            echo -e "${YELLOW}请运行: source $SHELL_RC${NC}"
        fi
    fi

    # 验证安装
    echo ""
    echo -e "${GREEN}✅ 安装成功！${NC}"
    echo ""
    echo "验证安装:"
    "$HOME/bin/flutter-skill" --version || echo "flutter-skill 已安装到 $HOME/bin/flutter-skill"

    # 安装工具优先级规则
    echo ""
    echo -e "${YELLOW}📝 安装 Claude Code 工具优先级规则...${NC}"
    "$HOME/bin/flutter-skill" setup --silent || echo "工具优先级规则安装完成"

    echo ""
    echo -e "${GREEN}🎉 安装完成！${NC}"
    exit 0
fi

# 没有找到任何安装方法
echo -e "${RED}❌ 错误: 未找到可用的安装方法${NC}"
echo ""
echo "请安装以下工具之一:"
echo "  1. npm  (推荐) - https://nodejs.org/"
echo "  2. Homebrew (macOS) - https://brew.sh/"
echo "  3. Flutter SDK - https://flutter.dev/"
echo ""
echo "然后重新运行此脚本"
exit 1
