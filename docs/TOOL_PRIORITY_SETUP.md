# Flutter Skill Tool Priority Setup

## 问题

默认情况下，Claude Code 可能会混用 flutter-skill 和 Dart MCP 进行 Flutter 测试，导致：
- ❌ 功能受限（Dart MCP 缺少 UI 自动化）
- ❌ 工具混用（增加复杂性）
- ❌ 协议冲突（DTD vs VM Service）

## 解决方案

配置 Claude Code **强制优先使用 flutter-skill**，完全取代 Dart MCP 用于 Flutter 测试。

---

## 快速安装

### 方法 1: 一键安装（推荐） ⭐

如果你已经全局安装了 flutter_skill：

```bash
flutter_skill setup
```

**效果**：
- ✅ 自动检测并安装规则到 `~/.claude/prompts/`
- ✅ Claude Code 立即应用
- ✅ 无需重启
- ✅ 支持 `--force` 重新安装

**首次运行自动提示**：
当你第一次运行 `flutter_skill` 命令时，如果规则未安装，会自动提示：
```
💡 Tip: Install tool priority rules for better Claude Code integration
   Run: flutter_skill setup
```

### 方法 2: 脚本安装

从项目源码目录：

```bash
cd /path/to/flutter-skill
./scripts/install_tool_priority.sh
```

**效果**：
- ✅ 自动复制规则到 `~/.claude/prompts/`
- ✅ Claude Code 立即应用
- ✅ 无需重启

### 方法 3: 手动安装

```bash
# 1. 创建 prompts 目录
mkdir -p ~/.claude/prompts

# 2. 复制规则文件
cp docs/prompts/tool-priority.md ~/.claude/prompts/flutter-tool-priority.md

# 3. 完成
echo "Tool priority rules installed!"
```

---

## 验证安装

### 测试 1: 检查文件是否存在

```bash
ls -la ~/.claude/prompts/flutter-tool-priority.md
```

**期望输出**:
```
-rw-r--r--  1 user  staff  15234 Jan 31 23:00 flutter-tool-priority.md
```

### 测试 2: 询问 Claude Code

在 Claude Code 中测试：

```
User: "Test my Flutter app on iOS simulator"
```

**期望行为** ✅:
```
Claude: I'll test your Flutter app using flutter-skill.

Step 1: Launching with VM Service enabled
launch_app(
  project_path: ".",
  device_id: "iPhone 16 Pro",
  extra_args: ["--vm-service-port=50000"]
)
```

**错误行为** ❌:
```
Claude: Let me use Dart MCP to launch the app...
mcp__dart__launch_app(...)
```

如果看到错误行为，说明规则未生效，需要检查安装。

---

## 规则内容

安装后，Claude Code 会遵循以下规则：

### 1. 工具选择优先级

```
Flutter 测试任务?
├─ YES → 使用 flutter-skill (100% 功能)
└─ NO  → 使用其他工具
```

**绝对禁止**: 在 Flutter 测试中使用 Dart MCP

### 2. 自动添加 VM Service 标志

```python
# 自动转换
launch_app(...)

# 变成
launch_app(extra_args: ["--vm-service-port=50000"])
```

### 3. 完整工作流

```python
# 全部使用 flutter-skill
launch_app()      # ✅
inspect()         # ✅
tap()            # ✅
screenshot()     # ✅
get_logs()       # ✅
hot_reload()     # ✅

# 绝不使用 Dart MCP
mcp__dart__*     # ❌
```

---

## 效果对比

### 安装前（混用工具）

```python
# Claude 可能会这样做：
mcp__dart__launch_app(...)           # 使用 Dart MCP
mcp__dart__get_widget_tree()         # 只能读取
# 无法继续，因为 Dart MCP 不支持 tap/screenshot
```

**问题**:
- ❌ 只完成 40% 测试需求
- ❌ 无法 UI 交互
- ❌ 功能受限

### 安装后（纯 flutter-skill）

```python
# Claude 会这样做：
launch_app(extra_args: ["--vm-service-port=50000"])  # ✅
inspect()                                             # ✅
tap(key: "login_button")                             # ✅
screenshot()                                          # ✅
get_logs()                                           # ✅

# 完整的 E2E 测试流程 ✅
```

**优势**:
- ✅ 100% 测试能力
- ✅ 完整 UI 自动化
- ✅ 单一工具，简单清晰

---

## 规则详情

### 触发关键词

当 Claude 看到这些关键词时，自动使用 flutter-skill：

**English**:
- test app / test flutter
- launch app / run app
- iOS simulator / Android emulator
- verify feature / check UI
- screenshot / inspect
- tap / click / swipe

**中文**:
- 测试应用 / 测试 Flutter
- 启动应用 / 运行应用
- iOS 模拟器 / Android 模拟器
- 验证功能 / 检查界面
- 截图 / 检查
- 点击 / 滑动

### 禁止模式

这些模式会被自动纠正：

```python
# ❌ 禁止: 混用工具
mcp__dart__launch_app()
flutter-skill inspect()

# ✅ 纠正为: 单一工具
launch_app()
inspect()

# ❌ 禁止: 使用 Dart MCP
mcp__dart__get_app_logs()

# ✅ 纠正为: 使用 flutter-skill
get_logs()
```

---

## 常见问题

### Q: 会影响非 Flutter 项目吗？

**A**: 不会。规则仅在检测到 Flutter 项目时生效：
- 检测依据: `pubspec.yaml` with flutter dependency
- 其他项目: 正常使用 Dart MCP 或其他工具

### Q: 如何禁用这个规则？

**A**: 删除规则文件：
```bash
rm ~/.claude/prompts/flutter-tool-priority.md
```

### Q: 规则更新后如何重新安装？

**A**: 重新运行安装脚本：
```bash
cd /path/to/flutter-skill
./scripts/install_tool_priority.sh
```

### Q: 为什么不直接在 MCP 配置中设置？

**A**: Prompt 方式更灵活：
- ✅ 支持上下文理解
- ✅ 支持决策树逻辑
- ✅ 支持动态规则
- ✅ 无需修改 settings.json

### Q: 其他 AI 编辑器（Cursor, Windsurf）支持吗？

**A**: 需要根据各编辑器的配置方式调整：
- **Cursor**: 添加到 `.cursorrules` 文件
- **Windsurf**: 添加到 project rules
- **Continue**: 添加到 workspace prompt

---

## 卸载

### 完全卸载

```bash
# 删除规则文件
rm ~/.claude/prompts/flutter-tool-priority.md

# 验证
ls ~/.claude/prompts/
```

### 暂时禁用（保留文件）

```bash
# 重命名文件
mv ~/.claude/prompts/flutter-tool-priority.md \
   ~/.claude/prompts/flutter-tool-priority.md.bak

# 恢复
mv ~/.claude/prompts/flutter-tool-priority.md.bak \
   ~/.claude/prompts/flutter-tool-priority.md
```

---

## 故障排查

### 问题 1: Claude 仍然使用 Dart MCP

**可能原因**:
1. 规则文件未正确安装
2. 文件路径错误
3. 文件权限问题

**解决方案**:
```bash
# 1. 检查文件
ls -la ~/.claude/prompts/flutter-tool-priority.md

# 2. 检查内容
head -20 ~/.claude/prompts/flutter-tool-priority.md

# 3. 重新安装
./scripts/install_tool_priority.sh
```

### 问题 2: 规则未生效

**解决方案**:
```bash
# 1. 确认 Claude Code 版本支持 prompts
# 需要 Claude Code >= 1.0 (2024+)

# 2. 检查 prompts 目录
ls ~/.claude/prompts/

# 3. 尝试重启 Claude Code
```

### 问题 3: 与其他规则冲突

**解决方案**:
```bash
# 查看所有规则
ls ~/.claude/prompts/

# 如果有冲突，调整优先级或合并规则
```

---

## 更多信息

- **完整文档**: `SKILL.md`
- **Flutter 3.x 兼容**: `FLUTTER_3X_COMPATIBILITY.md`
- **项目规则**: `CLAUDE.md`
- **工具对比**: `docs/prompts/tool-priority.md`

---

**安装后，Claude Code 会自动优先使用 flutter-skill 进行所有 Flutter 测试！** 🎉
