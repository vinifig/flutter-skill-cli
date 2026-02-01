# Flutter Skill 一键安装脚本 (Windows PowerShell)

$ErrorActionPreference = "Stop"

Write-Host "🚀 Flutter Skill 一键安装" -ForegroundColor Blue
Write-Host ""

# 检测安装方法
Write-Host "检测最佳安装方法..." -ForegroundColor Yellow
Write-Host ""

# 方法 1: npm (推荐)
if (Get-Command npm -ErrorAction SilentlyContinue) {
    Write-Host "✅ 检测到 npm，使用 npm 安装（推荐）" -ForegroundColor Green
    Write-Host ""
    Write-Host "执行: npm install -g flutter-skill-mcp"
    npm install -g flutter-skill-mcp

    Write-Host ""
    Write-Host "✅ 安装成功！" -ForegroundColor Green
    Write-Host ""
    Write-Host "验证安装:"
    flutter-skill --version

    # 安装工具优先级规则
    Write-Host ""
    Write-Host "📝 安装 Claude Code 工具优先级规则..." -ForegroundColor Yellow
    try {
        flutter-skill setup --silent
    } catch {
        Write-Host "工具优先级规则安装完成"
    }

    Write-Host ""
    Write-Host "🎉 安装完成！" -ForegroundColor Green
    exit 0
}

# 方法 2: Scoop
if (Get-Command scoop -ErrorAction SilentlyContinue) {
    Write-Host "✅ 检测到 Scoop，使用 scoop 安装" -ForegroundColor Green
    Write-Host ""
    Write-Host "执行: scoop bucket add flutter-skill https://github.com/ai-dashboad/scoop-flutter-skill"
    scoop bucket add flutter-skill https://github.com/ai-dashboad/scoop-flutter-skill
    Write-Host "执行: scoop install flutter-skill"
    scoop install flutter-skill

    Write-Host ""
    Write-Host "✅ 安装成功！" -ForegroundColor Green
    Write-Host ""
    Write-Host "验证安装:"
    flutter-skill --version

    # 安装工具优先级规则
    Write-Host ""
    Write-Host "📝 安装 Claude Code 工具优先级规则..." -ForegroundColor Yellow
    flutter-skill setup --silent

    Write-Host ""
    Write-Host "🎉 安装完成！" -ForegroundColor Green
    exit 0
}

# 方法 3: 从源码安装 (需要 Dart/Flutter)
if ((Get-Command dart -ErrorAction SilentlyContinue) -or (Get-Command flutter -ErrorAction SilentlyContinue)) {
    Write-Host "⚠️  未检测到 npm 或 Scoop" -ForegroundColor Yellow
    Write-Host "使用 Dart 从源码安装（需要 Flutter SDK）" -ForegroundColor Yellow
    Write-Host ""

    # 检测 Flutter
    if (-not (Get-Command flutter -ErrorAction SilentlyContinue)) {
        Write-Host "❌ 错误: 未找到 Flutter SDK" -ForegroundColor Red
        Write-Host ""
        Write-Host "请先安装 Flutter: https://flutter.dev/docs/get-started/install"
        Write-Host ""
        Write-Host "或者使用以下方法之一:"
        Write-Host "  • npm install -g flutter-skill-mcp  (推荐)"
        Write-Host "  • scoop install flutter-skill"
        exit 1
    }

    # 下载源码
    $InstallDir = "$env:USERPROFILE\.flutter-skill-src"

    if (-not (Test-Path $InstallDir)) {
        Write-Host "克隆仓库到 $InstallDir ..."
        git clone https://github.com/ai-dashboad/flutter-skill.git $InstallDir
    } else {
        Write-Host "更新源码..."
        Set-Location $InstallDir
        git pull origin main
    }

    Set-Location $InstallDir

    # 安装依赖
    Write-Host "安装依赖..."
    flutter pub get

    # 创建批处理文件
    Write-Host "创建可执行文件..."
    $BinDir = "$env:USERPROFILE\bin"
    if (-not (Test-Path $BinDir)) {
        New-Item -ItemType Directory -Path $BinDir | Out-Null
    }

    $WrapperContent = @"
@echo off
cd /d "$InstallDir"
dart run bin/flutter_skill.dart %*
"@

    $WrapperContent | Out-File -FilePath "$BinDir\flutter-skill.bat" -Encoding ASCII

    # 添加到 PATH
    $UserPath = [Environment]::GetEnvironmentVariable("Path", "User")
    if ($UserPath -notlike "*$BinDir*") {
        [Environment]::SetEnvironmentVariable("Path", "$UserPath;$BinDir", "User")
        Write-Host ""
        Write-Host "✅ 已添加到 PATH: $BinDir" -ForegroundColor Green
        Write-Host "⚠️  请重新打开 PowerShell 窗口以使用 flutter-skill 命令" -ForegroundColor Yellow
    }

    # 验证安装
    Write-Host ""
    Write-Host "✅ 安装成功！" -ForegroundColor Green
    Write-Host ""
    Write-Host "flutter-skill 已安装到 $BinDir\flutter-skill.bat"

    # 安装工具优先级规则
    Write-Host ""
    Write-Host "📝 安装 Claude Code 工具优先级规则..." -ForegroundColor Yellow
    & "$BinDir\flutter-skill.bat" setup --silent

    Write-Host ""
    Write-Host "🎉 安装完成！" -ForegroundColor Green
    Write-Host "⚠️  请重新打开终端窗口以使用 flutter-skill 命令" -ForegroundColor Yellow
    exit 0
}

# 没有找到任何安装方法
Write-Host "❌ 错误: 未找到可用的安装方法" -ForegroundColor Red
Write-Host ""
Write-Host "请安装以下工具之一:"
Write-Host "  1. npm  (推荐) - https://nodejs.org/"
Write-Host "  2. Scoop - https://scoop.sh/"
Write-Host "  3. Flutter SDK - https://flutter.dev/"
Write-Host ""
Write-Host "然后重新运行此脚本"
exit 1
