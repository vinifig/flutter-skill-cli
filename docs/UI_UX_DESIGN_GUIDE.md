# Flutter Skill UI/UX 设计指南

> **跨平台统一设计系统** - VSCode & IntelliJ IDEA

---

## 目录

1. [跨平台设计原则](#1-跨平台设计原则)
2. [统一设计语言](#2-统一设计语言)
3. [界面结构（统一布局）](#3-界面结构统一布局)
4. [平台特定实现](#4-平台特定实现)
5. [组件规范](#5-组件规范)
6. [交互流程](#6-交互流程)
7. [实现指南](#7-实现指南)

---

## 1. 跨平台设计原则

### 1.1 核心理念（Platform-Agnostic）

这些原则适用于所有平台，确保用户体验一致：

- **引导式（Guided）** - 新手能快速上手，专家能高效操作
- **状态清晰（Status Clarity）** - 任何时候都能看到当前状态
- **错误友好（Error-Friendly）** - 错误提示包含解决方案
- **渐进式（Progressive）** - 高级功能不干扰基础使用
- **一致性（Consistency）** - 相同功能在不同平台表现一致

### 1.2 平台适配原则（Platform Adaptation）

尊重各平台的原生体验：

| 原则 | VSCode | IntelliJ IDEA |
|-----|--------|---------------|
| **视觉语言** | Codicons + Webview UI | IntelliJ Icons + Swing |
| **布局方式** | Sidebar + Webview | Tool Window + Panel |
| **主题系统** | VSCode Themes | IntelliJ Themes |
| **快捷键** | Ctrl/Cmd + Shift + F | Alt/Cmd + F |
| **通知系统** | VSCode Notifications | IntelliJ Balloons |

**关键点**：
- ✅ **功能一致** - 相同的功能集合
- ✅ **布局一致** - 相同的信息层次
- ✅ **交互一致** - 相同的操作流程
- ⚠️ **外观适配** - 遵循平台原生风格

### 1.3 设计决策矩阵

当面临设计选择时，使用此决策表：

| 场景 | 统一方案 | VSCode 特有 | IntelliJ 特有 |
|-----|---------|------------|--------------|
| 连接状态显示 | ✅ 卡片 + 指示灯 | Sidebar | Tool Window |
| 快速操作按钮 | ✅ 2x2 网格 | Webview | JPanel |
| 元素列表 | ✅ 树形 + 详情 | TreeView | JTree |
| 截图查看器 | ✅ 图片 + 标注 | Webview Panel | ImageComponent |
| 日志查看 | ✅ 过滤 + 搜索 | Output Channel | Console |
| 设置界面 | ✅ 表单 + 分组 | Settings UI | Configurable |

---

## 2. 统一设计语言

### 2.1 通用设计系统（Design Tokens）

这些设计 token 在两个平台都保持一致的**相对值**：

```yaml
# 设计 Token（平台无关）
spacing:
  xxs: 2
  xs: 4
  sm: 8
  md: 12
  lg: 16
  xl: 24
  xxl: 32

font_size:
  xs: 10
  sm: 11
  md: 12
  lg: 14
  xl: 16

border_radius:
  sm: 3
  md: 4
  lg: 6

icon_size:
  sm: 16
  md: 20
  lg: 24
```

### 2.2 语义化颜色系统

使用语义化命名，各平台映射到原生颜色：

| 语义 | 用途 | VSCode 映射 | IntelliJ 映射 |
|-----|------|------------|--------------|
| `primary` | 主要操作 | `button.background` | `ActionButton.background` |
| `secondary` | 次要操作 | `button.secondaryBackground` | `Button.background` |
| `success` | 成功状态 | `testing.iconPassed` | `FileStatus.ADDED` |
| `warning` | 警告状态 | `testing.iconQueued` | `FileStatus.MODIFIED` |
| `error` | 错误状态 | `testing.iconFailed` | `FileStatus.DELETED` |
| `info` | 信息提示 | `charts.blue` | `Label.infoForeground` |
| `border` | 边框 | `panel.border` | `Component.borderColor` |
| `bg1` | 背景层1 | `sideBar.background` | `Panel.background` |
| `bg2` | 背景层2 | `sideBarSectionHeader.background` | `EditorPane.background` |
| `text` | 主文本 | `foreground` | `Label.foreground` |
| `textSecondary` | 次要文本 | `descriptionForeground` | `Label.disabledForeground` |

### 2.3 统一图标系统

使用语义化图标名称，各平台使用对应的原生图标：

| 功能 | 图标名（语义） | VSCode Icon | IntelliJ Icon |
|-----|-----------|------------|--------------|
| 连接状态-已连接 | `status.connected` | `$(debug-alt)` + green | `AllIcons.Debugger.ThreadAtBreakpoint` |
| 连接状态-未连接 | `status.disconnected` | `$(debug-disconnect)` | `AllIcons.Debugger.ThreadSuspended` |
| 连接状态-连接中 | `status.connecting` | `$(loading~spin)` | `AnimatedIcon.Default` |
| 启动应用 | `action.launch` | `$(debug-start)` | `AllIcons.Actions.Execute` |
| 检查界面 | `action.inspect` | `$(search)` | `AllIcons.Actions.Find` |
| 截图 | `action.screenshot` | `$(device-camera)` | `AllIcons.Actions.Dump` |
| 热重载 | `action.reload` | `$(refresh)` | `AllIcons.Actions.Refresh` |
| Tap 操作 | `action.tap` | `$(hand)` | `AllIcons.Gutter.JavadocRead` |
| 输入文本 | `action.input` | `$(edit)` | `AllIcons.Actions.Edit` |
| 设置 | `action.settings` | `$(settings-gear)` | `AllIcons.General.Settings` |
| 帮助 | `action.help` | `$(question)` | `AllIcons.Actions.Help` |
| 历史 | `action.history` | `$(history)` | `AllIcons.Vcs.History` |

---

## 3. 界面结构（统一布局）

### 3.1 主界面布局（Platform-Independent Structure）

两个平台使用相同的信息架构和视觉层次：

```
┌────────────────────────────────────────┐
│ HEADER (Title + Actions)               │ ← 相同
├────────────────────────────────────────┤
│                                        │
│ 1. CONNECTION STATUS CARD              │ ← 相同
│    - Status Badge (Connected/Not)      │
│    - Device Info                       │
│    - Actions (Disconnect/Refresh)      │
│                                        │
├────────────────────────────────────────┤
│                                        │
│ 2. QUICK ACTIONS (2x2 Grid)           │ ← 相同
│    [Launch]  [Inspect]                │
│    [Screenshot] [Reload]               │
│                                        │
├────────────────────────────────────────┤
│                                        │
│ 3. INTERACTIVE ELEMENTS (Tree)        │ ← 相同
│    📱 HomePage                          │
│      ├─ 🔘 login_button               │
│      ├─ 📝 email_field                │
│      └─ 📝 password_field             │
│    [Element actions panel]            │
│                                        │
├────────────────────────────────────────┤
│                                        │
│ 4. RECENT ACTIVITY (List)             │ ← 相同
│    ✅ Login test (2m ago)              │
│    📸 Screenshot (5m ago)              │
│                                        │
├────────────────────────────────────────┤
│                                        │
│ 5. AI EDITORS STATUS                  │ ← 相同
│    ✅ Claude Code                      │
│    ⚠️  Windsurf                        │
│                                        │
└────────────────────────────────────────┘
```

### 3.2 Inspector 详细视图（统一布局）

```
┌──────────────────────────────────────────────┐
│ 🔍 UI Inspector          [Screenshot][✕]    │
├──────────────────────────────────────────────┤
│                                              │
│  LEFT PANEL (50%)        RIGHT PANEL (50%)   │
│  ┌─────────────┐        ┌─────────────────┐ │
│  │             │        │ Element Details │ │
│  │ Screenshot  │        │                 │ │
│  │   with      │        │ Type: Button    │ │
│  │ highlights  │        │ Text: "Login"   │ │
│  │             │        │ Position: ...   │ │
│  │             │        │                 │ │
│  └─────────────┘        │ [Actions]       │ │
│                         └─────────────────┘ │
│                                              │
│  BOTTOM: Element Tree                        │
│  ├─ HomePage                                 │
│  │  ├─ login_button                         │
│  │  └─ email_field                          │
│                                              │
└──────────────────────────────────────────────┘
```

---

## 4. 平台特定实现

### 4.1 VSCode 插件实现

## 2. 界面结构重新设计

### 2.1 侧边栏（Primary Sidebar）

```
┌─────────────────────────────────────┐
│ 🎯 Flutter Skill               [⚙️][?] │
├─────────────────────────────────────┤
│                                     │
│ ╔═══ Connection Status ═══╗        │
│ ║  🟢 Connected                    ║
│ ║  📱 iPhone 16 Pro                ║
│ ║  ⚡ VM Service: :50000           ║
│ ║  [Disconnect] [Refresh]          ║
│ ╚══════════════════════════════════╝│
│                                     │
│ ┌─── Quick Actions ────────────┐   │
│ │ [▶️ Launch App     ]          │   │
│ │ [🔍 Inspect UI     ]          │   │
│ │ [📸 Screenshot     ]          │   │
│ │ [🔄 Hot Reload     ]          │   │
│ └──────────────────────────────┘   │
│                                     │
│ ┌─── Interactive Elements ─────┐   │
│ │ 📱 HomePage                   │   │
│ │   ├─ 🔘 login_button          │   │
│ │   ├─ 📝 email_field           │   │
│ │   └─ 📝 password_field        │   │
│ │ [Tap] [Input] [Inspect]       │   │
│ └──────────────────────────────┘   │
│                                     │
│ ┌─── Testing History ──────────┐   │
│ │ ✅ Login flow test (2m ago)  │   │
│ │ ✅ Screenshot capture         │   │
│ │ ❌ Form validation (5m ago)  │   │
│ │ [View All]                    │   │
│ └──────────────────────────────┘   │
│                                     │
│ ┌─── AI Editors ───────────────┐   │
│ │ ✅ Claude Code                │   │
│ │ ✅ Cursor                     │   │
│ │ ⚠️  Windsurf (Setup needed)  │   │
│ │ [Configure]                   │   │
│ └──────────────────────────────┘   │
└─────────────────────────────────────┘
```

### 2.2 Webview 面板（详细视图）

**Inspector 视图:**
```
┌─────────────────────────────────────────────────┐
│ 🔍 UI Inspector                    [📸][🔄][✕] │
├─────────────────────────────────────────────────┤
│                                                 │
│  ┌─────────── Screenshot ────────────┐         │
│  │                                   │         │
│  │     [App screenshot preview]      │         │
│  │     with element highlights       │         │
│  │                                   │         │
│  └───────────────────────────────────┘         │
│                                                 │
│  📋 Interactive Elements (12 found)             │
│  ┌───────────────────────────────────────────┐ │
│  │ ┌─ login_button ────────────────────────┐ │ │
│  │ │ Type: ElevatedButton                  │ │ │
│  │ │ Text: "Login"                         │ │ │
│  │ │ Position: (x: 156, y: 420)            │ │ │
│  │ │ Size: 120x48                          │ │ │
│  │ │ [Tap] [Highlight] [Properties]        │ │ │
│  │ └───────────────────────────────────────┘ │ │
│  │                                           │ │
│  │ ┌─ email_field ─────────────────────────┐ │ │
│  │ │ Type: TextField                       │ │ │
│  │ │ Hint: "Enter email"                   │ │ │
│  │ │ Value: "test@example.com"             │ │ │
│  │ │ [Input Text] [Clear] [Properties]     │ │ │
│  │ └───────────────────────────────────────┘ │ │
│  └───────────────────────────────────────────┘ │
│                                                 │
│  🎯 Quick Test Builder                          │
│  ┌─────────────────────────────────────────┐   │
│  │ 1. Tap "email_field"        [▶️][✕]     │   │
│  │ 2. Input "test@example.com" [▶️][✕]     │   │
│  │ 3. Tap "login_button"       [▶️][✕]     │   │
│  │ [+ Add Step] [▶️ Run All] [💾 Save]     │   │
│  └─────────────────────────────────────────┘   │
└─────────────────────────────────────────────────┘
```

### 2.3 状态栏（Status Bar）

```
┌──────────────────────────────────────────────────────┐
│ ... │ 🎯 Flutter: Connected (iPhone 16 Pro) │ ... │
└──────────────────────────────────────────────────────┘
        ↑ 点击打开 Quick Actions
```

---

## 3. 详细设计规范

### 3.1 颜色系统

```typescript
// 基于 VSCode 主题变量
const colors = {
  // 状态颜色
  success: 'var(--vscode-testing-iconPassed)',      // 绿色
  warning: 'var(--vscode-testing-iconQueued)',      // 黄色
  error: 'var(--vscode-testing-iconFailed)',        // 红色
  info: 'var(--vscode-charts-blue)',                // 蓝色

  // 功能颜色
  primary: 'var(--vscode-button-background)',
  secondary: 'var(--vscode-button-secondaryBackground)',

  // 边框和分隔
  border: 'var(--vscode-panel-border)',
  divider: 'var(--vscode-widget-border)',

  // 背景层次
  bg1: 'var(--vscode-sideBar-background)',
  bg2: 'var(--vscode-sideBarSectionHeader-background)',
  bg3: 'var(--vscode-input-background)',
}
```

### 3.2 图标系统

使用 Codicons + 自定义图标：

| 功能 | 图标 | Codicon |
|-----|------|---------|
| 连接状态 | 🟢🟡🔴 | `circle-filled` + color |
| 启动应用 | ▶️ | `debug-start` |
| 检查界面 | 🔍 | `search` |
| 截图 | 📸 | `device-camera` |
| 热重载 | 🔄 | `refresh` |
| Tap 操作 | 👆 | `hand` |
| 输入文本 | ⌨️ | `edit` |
| 历史记录 | 📜 | `history` |
| 设置 | ⚙️ | `settings-gear` |
| 帮助 | ❓ | `question` |

### 3.3 间距系统

```typescript
const spacing = {
  xxs: '2px',
  xs: '4px',
  sm: '8px',
  md: '12px',
  lg: '16px',
  xl: '24px',
  xxl: '32px',
}
```

### 3.4 组件规范

#### Button

```typescript
// Primary Action
<vscode-button appearance="primary">
  Launch App
</vscode-button>

// Secondary Action
<vscode-button appearance="secondary">
  Inspect
</vscode-button>

// Icon Button
<vscode-button appearance="icon" aria-label="Settings">
  <span class="codicon codicon-settings-gear"></span>
</vscode-button>
```

#### Card/Panel

```css
.card {
  background: var(--vscode-sideBarSectionHeader-background);
  border: 1px solid var(--vscode-panel-border);
  border-radius: 4px;
  padding: 12px;
  margin: 8px 0;
}

.card-header {
  display: flex;
  align-items: center;
  gap: 8px;
  font-weight: 600;
  margin-bottom: 8px;
}
```

#### Status Badge

```html
<span class="status-badge status-connected">
  <span class="codicon codicon-circle-filled"></span>
  Connected
</span>

<style>
.status-badge {
  display: inline-flex;
  align-items: center;
  gap: 4px;
  padding: 2px 8px;
  border-radius: 12px;
  font-size: 11px;
}

.status-connected {
  background: var(--vscode-testing-iconPassed);
  color: white;
}
</style>
```

---

## 4. 交互流程优化

### 4.1 首次使用流程（Onboarding）

```
┌─────────────────────────────────────┐
│ 👋 Welcome to Flutter Skill         │
├─────────────────────────────────────┤
│                                     │
│ Let's get you set up in 3 steps:   │
│                                     │
│ ✅ 1. Flutter SDK detected          │
│    └─ Flutter 3.24.0                │
│                                     │
│ ⏳ 2. Install tool priority rules   │
│    [Install Now] (Recommended)      │
│    This ensures Claude always uses  │
│    Flutter Skill for testing.       │
│                                     │
│ ⏳ 3. Configure AI editor            │
│    Which editor are you using?      │
│    ○ Claude Code                    │
│    ○ Cursor                         │
│    ○ Windsurf                       │
│    ○ Skip for now                   │
│                                     │
│ [Get Started]  [Show me a demo]     │
└─────────────────────────────────────┘
```

### 4.2 连接流程

```
┌─────────────────────────────────────┐
│ 📱 Connect to Flutter App           │
├─────────────────────────────────────┤
│                                     │
│ Choose how to connect:              │
│                                     │
│ ┌─────────────────────────────┐    │
│ │ ▶️ Launch new app           │    │
│ │   Start your Flutter app    │    │
│ │   with auto-connect         │    │
│ │   [Select Device ▼]         │    │
│ └─────────────────────────────┘    │
│                                     │
│ ┌─────────────────────────────┐    │
│ │ 🔗 Connect to running app   │    │
│ │   Scan for running apps     │    │
│ │   [Scan Now]                │    │
│ └─────────────────────────────┘    │
│                                     │
│ ┌─────────────────────────────┐    │
│ │ 🔧 Manual connection        │    │
│ │   VM Service URI:           │    │
│ │   [ws://127.0.0.1:50000]    │    │
│ │   [Connect]                 │    │
│ └─────────────────────────────┘    │
│                                     │
│ [Cancel]                            │
└─────────────────────────────────────┘
```

### 4.3 错误处理流程

**Before (现在):**
```
❌ Connection error. Click for options.
```

**After (改进后):**
```
┌─────────────────────────────────────┐
│ ⚠️ Connection Failed                │
├─────────────────────────────────────┤
│                                     │
│ Problem:                            │
│ Could not connect to VM Service     │
│                                     │
│ Possible causes:                    │
│ • App is using DTD protocol         │
│ • App is not running                │
│ • Firewall blocking connection      │
│                                     │
│ Quick fixes:                        │
│ ┌─────────────────────────────┐    │
│ │ ⚡ Add --vm-service-port flag │   │
│ │   flutter run -d "iPhone"   │   │
│ │     --vm-service-port=50000 │   │
│ │   [Copy Command]            │   │
│ └─────────────────────────────┘    │
│                                     │
│ ┌─────────────────────────────┐    │
│ │ 🔄 Restart app with flag    │   │
│ │   [Restart Now]             │   │
│ └─────────────────────────────┘    │
│                                     │
│ [View Full Guide] [Report Issue]   │
└─────────────────────────────────────┘
```

---

## 5. 高级功能设计

### 5.1 Test Builder（可视化测试构建器）

```
┌───────────────────────────────────────────┐
│ 🧪 Test Builder                     [✕]   │
├───────────────────────────────────────────┤
│                                           │
│ Test Name: Login Flow Test               │
│ [───────────────────────────────]         │
│                                           │
│ Steps:                                    │
│ ┌───────────────────────────────────┐     │
│ │ 1. [👆 Tap] email_field           │     │
│ │    ↓                              │     │
│ │ 2. [⌨️ Input] "test@example.com"  │     │
│ │    ↓                              │     │
│ │ 3. [👆 Tap] password_field        │     │
│ │    ↓                              │     │
│ │ 4. [⌨️ Input] "password123"       │     │
│ │    ↓                              │     │
│ │ 5. [👆 Tap] login_button          │     │
│ │    ↓                              │     │
│ │ 6. [⏱️ Wait] for "Welcome" text   │     │
│ │    ↓                              │     │
│ │ 7. [📸 Screenshot] "success"      │     │
│ └───────────────────────────────────┘     │
│                                           │
│ [+ Add Step ▼]                            │
│   • Tap element                           │
│   • Input text                            │
│   • Wait for element                      │
│   • Screenshot                            │
│   • Assert text                           │
│                                           │
│ [▶️ Run Test] [💾 Save] [📋 Copy Code]    │
└───────────────────────────────────────────┘
```

### 5.2 Logs Viewer

```
┌─────────────────────────────────────────┐
│ 📜 Application Logs            [Clear]  │
├─────────────────────────────────────────┤
│ Filters: [All ▼] [Search...]            │
│ ┌─ ℹ️ Info  ─ ⚠️ Warn  ─ ❌ Error ──┐   │
│ │ 12:34:56 ℹ️  App started            │   │
│ │ 12:34:57 ℹ️  Navigated to /login    │   │
│ │ 12:34:58 ⚠️  Slow API response      │   │
│ │ 12:35:01 ❌ Auth failed: invalid    │   │
│ │              credentials            │   │
│ │              [View Stack Trace]     │   │
│ └────────────────────────────────────┘   │
│                                          │
│ [📥 Export] [🔍 Find] [⚙️ Settings]      │
└─────────────────────────────────────────┘
```

---

## 6. 配置界面优化

### Before (现在):
```
MCP Configuration

Add to your AI agent's MCP config:
{
  "mcpServers": {
    "flutter-skill": {
      ...
}
```

### After (改进后):
```
┌─────────────────────────────────────────┐
│ ⚙️ Settings                             │
├─────────────────────────────────────────┤
│                                         │
│ 🤖 AI Editor Integration                │
│ ┌───────────────────────────────────┐   │
│ │ Editor: [Claude Code       ▼]     │   │
│ │                                   │   │
│ │ ✅ Tool priority rules installed  │   │
│ │ ✅ MCP server configured          │   │
│ │                                   │   │
│ │ [Test Connection]                 │   │
│ └───────────────────────────────────┘   │
│                                         │
│ 📱 Default Device                       │
│ ┌───────────────────────────────────┐   │
│ │ [iPhone 16 Pro         ▼]         │   │
│ │ ☑️ Auto-launch on startup          │   │
│ └───────────────────────────────────┘   │
│                                         │
│ 🔧 Advanced Settings                    │
│ ┌───────────────────────────────────┐   │
│ │ VM Service Port: [50000]          │   │
│ │ Screenshot Quality: [─────●───]   │   │
│ │                       High        │   │
│ │ ☑️ Auto-reload on save             │   │
│ │ ☑️ Show notifications              │   │
│ └───────────────────────────────────┘   │
│                                         │
│ [Reset to Defaults]                     │
└─────────────────────────────────────────┘
```

---

## 7. 实现优先级

### Phase 1: 基础改进 (Week 1-2)
- ✅ 状态栏集成
- ✅ 连接状态卡片
- ✅ 错误提示优化
- ✅ 按钮分组和图标

### Phase 2: 核心功能 (Week 3-4)
- ✅ Inspector Webview
- ✅ Interactive Elements 列表
- ✅ Quick Actions 面板
- ✅ Onboarding 流程

### Phase 3: 高级功能 (Week 5-6)
- ✅ Test Builder
- ✅ Logs Viewer
- ✅ History Tracking
- ✅ 设置界面

### Phase 4: 打磨优化 (Week 7-8)
- ✅ 动画和过渡
- ✅ 快捷键支持
- ✅ 主题适配
- ✅ 性能优化

---

## 8. 技术栈建议

### VSCode Extension
```typescript
// extension.ts
import * as vscode from 'vscode';
import { FlutterSkillViewProvider } from './views/FlutterSkillViewProvider';

export function activate(context: vscode.ExtensionContext) {
  // 注册侧边栏
  const provider = new FlutterSkillViewProvider(context.extensionUri);

  context.subscriptions.push(
    vscode.window.registerWebviewViewProvider(
      'flutter-skill.sidebarView',
      provider
    )
  );

  // 注册状态栏
  const statusBar = vscode.window.createStatusBarItem(
    vscode.StatusBarAlignment.Left,
    100
  );
  statusBar.text = "$(debug-disconnect) Flutter: Disconnected";
  statusBar.command = 'flutter-skill.showQuickActions';
  statusBar.show();
}
```

### Webview UI
```typescript
// Use VSCode Webview UI Toolkit
import {
  provideVSCodeDesignSystem,
  vsCodeButton,
  vsCodeTextField,
  vsCodePanels,
  vsCodeProgressRing,
} from "@vscode/webview-ui-toolkit";

provideVSCodeDesignSystem().register(
  vsCodeButton(),
  vsCodeTextField(),
  vsCodePanels(),
  vsCodeProgressRing()
);
```

### 状态管理
```typescript
// 使用 Zustand 或 Context API
interface FlutterSkillState {
  connectionStatus: 'connected' | 'disconnected' | 'connecting';
  device: Device | null;
  elements: UIElement[];
  testHistory: TestRun[];
}
```

---

## 9. 用户体验指标

### 成功标准
- ⏱️ 首次连接时间 < 10秒
- 🎯 新用户完成首次测试 < 2分钟
- 📊 错误自助解决率 > 80%
- ⭐ 用户满意度 > 4.5/5

### 测试检查清单
- [ ] 支持浅色/深色主题
- [ ] 键盘导航完整
- [ ] 屏幕阅读器兼容
- [ ] 动画可禁用
- [ ] 高对比度模式支持

---

## 10. 参考资源

### 设计系统
- [VSCode UX Guidelines](https://code.visualstudio.com/api/ux-guidelines/overview)
- [Codicons](https://microsoft.github.io/vscode-codicons/dist/codicon.html)
- [Webview UI Toolkit](https://github.com/microsoft/vscode-webview-ui-toolkit)

### 优秀示例
- GitLens
- Docker Extension
- Test Explorer UI
- Flutter DevTools (参考)

---

**最后更新**: 2026-02-01
**版本**: 1.0
**维护者**: Flutter Skill Team

**技术栈**:
- TypeScript + VSCode Extension API
- Webview UI Toolkit
- React/Vue (可选，用于复杂视图)

**关键API**:
```typescript
// Sidebar View
vscode.window.registerWebviewViewProvider(
  'flutter-skill.sidebarView',
  provider
);

// Status Bar
const statusBar = vscode.window.createStatusBarItem(
  vscode.StatusBarAlignment.Left,
  100
);

// Inspector Panel
const panel = vscode.window.createWebviewPanel(
  'flutterSkillInspector',
  'UI Inspector',
  vscode.ViewColumn.Two,
  { enableScripts: true }
);
```

**颜色映射（VSCode）**:
```typescript
const colors = {
  primary: 'var(--vscode-button-background)',
  secondary: 'var(--vscode-button-secondaryBackground)',
  success: 'var(--vscode-testing-iconPassed)',
  warning: 'var(--vscode-testing-iconQueued)',
  error: 'var(--vscode-testing-iconFailed)',
  border: 'var(--vscode-panel-border)',
  bg1: 'var(--vscode-sideBar-background)',
  bg2: 'var(--vscode-sideBarSectionHeader-background)',
};
```

**组件示例（VSCode）**:
```html
<!-- Primary Button -->
<vscode-button appearance="primary">
  Launch App
</vscode-button>

<!-- Status Badge -->
<span class="status-badge connected">
  <span class="codicon codicon-circle-filled"></span>
  Connected
</span>

<!-- Card Component -->
<div class="card">
  <div class="card-header">
    <span class="codicon codicon-device-mobile"></span>
    Connection Status
  </div>
  <div class="card-content">
    <!-- content -->
  </div>
</div>
```

### 4.2 IntelliJ IDEA 插件实现

**技术栈**:
- Java/Kotlin + IntelliJ Platform SDK
- Swing Components
- IntelliJ UI DSL

**关键API**:
```kotlin
// Tool Window
class FlutterSkillToolWindowFactory : ToolWindowFactory {
  override fun createToolWindowContent(
    project: Project,
    toolWindow: ToolWindow
  ) {
    val contentManager = toolWindow.contentManager
    val mainPanel = FlutterSkillPanel(project)
    val content = contentManager.factory.createContent(
      mainPanel,
      "",
      false
    )
    contentManager.addContent(content)
  }
}

// Status Bar Widget
class FlutterSkillStatusWidget : StatusBarWidget {
  override fun getPresentation(): StatusBarWidget.WidgetPresentation {
    return object : StatusBarWidget.TextPresentation {
      override fun getText(): String {
        return "Flutter: Connected"
      }
      override fun getAlignment() = Component.CENTER_ALIGNMENT
    }
  }
}
```

**颜色映射（IntelliJ）**:
```kotlin
object FlutterSkillColors {
  val primary = JBUI.CurrentTheme.ActionButton.pressedBackground()
  val secondary = JBUI.CurrentTheme.Button.buttonColorStart()
  val success = FileStatus.ADDED.color
  val warning = FileStatus.MODIFIED.color
  val error = FileStatus.DELETED.color
  val border = JBUI.CurrentTheme.Component.borderColor()
  val bg1 = UIUtil.getPanelBackground()
  val bg2 = UIUtil.getEditorPaneBackground()
}
```

**组件示例（IntelliJ）**:
```kotlin
// Primary Button
JButton("Launch App").apply {
  putClientProperty("ActionButton.focusedBackground", primary)
}

// Status Panel
panel {
  row {
    icon(AllIcons.Debugger.ThreadAtBreakpoint)
    label("Connected").apply {
      foreground = FlutterSkillColors.success
    }
  }
  row {
    icon(AllIcons.General.Information)
    label("iPhone 16 Pro")
  }
}

// Card Component (IntelliJ UI DSL)
val card = panel {
  border = JBUI.Borders.customLine(borderColor, 1)
  background = bg2
  
  titledRow("Connection Status") {
    row {
      label("Device: iPhone 16 Pro")
    }
    row {
      button("Disconnect") { /* action */ }
      button("Refresh") { /* action */ }
    }
  }
}
```

### 4.3 平台差异对照表

| 功能 | VSCode 实现 | IntelliJ 实现 | 统一逻辑 |
|-----|-----------|--------------|---------|
| **侧边栏** | WebviewView | ToolWindow | ✅ 相同布局 |
| **按钮** | vscode-button | JButton | ✅ 相同文本 |
| **列表** | HTML List | JList/JTree | ✅ 相同数据 |
| **输入框** | vscode-text-field | JTextField | ✅ 相同验证 |
| **通知** | vscode.window.showInformationMessage | Notifications.Bus | ✅ 相同内容 |
| **设置** | settings.json | Configurable | ✅ 相同选项 |
| **快捷键** | keybindings | KeymapManager | ⚠️ 不同键位 |
| **主题** | CSS Variables | UIManager | ⚠️ 不同API |

---

## 5. 组件规范

### 5.1 连接状态卡片（Cross-Platform）

**规格**:
- **宽度**: 100% (容器宽度)
- **内边距**: `lg` (16px)
- **圆角**: `lg` (6px)
- **边框**: 1px solid `border`
- **背景**: `bg2`

**内容结构**:
```
┌────────────────────────┐
│ [Icon] Status Badge    │ ← Header
├────────────────────────┤
│ [Icon] Device Name     │ ← Info Row 1
│ [Icon] VM Service Port │ ← Info Row 2
├────────────────────────┤
│ [Disconnect] [Refresh] │ ← Actions
└────────────────────────┘
```

**实现对照**:

VSCode (HTML/CSS):
```html
<div class="status-card">
  <div class="status-header">
    <span class="status-badge connected">
      <span class="codicon codicon-circle-filled"></span>
      Connected
    </span>
  </div>
  <div class="status-info">
    <div class="info-row">
      <span class="codicon codicon-device-mobile"></span>
      <span>iPhone 16 Pro</span>
    </div>
  </div>
  <div class="status-actions">
    <vscode-button appearance="secondary">Disconnect</vscode-button>
    <vscode-button appearance="secondary">Refresh</vscode-button>
  </div>
</div>
```

IntelliJ (Kotlin UI DSL):
```kotlin
panel {
  border = JBUI.Borders.customLine(borderColor, 1)
  background = bg2
  
  row {
    icon(AllIcons.Debugger.ThreadAtBreakpoint)
    label("Connected") {
      foreground = successColor
      font = JBUI.Fonts.label(12).asBold()
    }
  }
  row {
    icon(AllIcons.General.Information)
    label("iPhone 16 Pro")
  }
  row {
    button("Disconnect") { disconnect() }
    button("Refresh") { refresh() }
  }
}
```

### 5.2 快速操作按钮（Cross-Platform）

**规格**:
- **布局**: 2x2 网格
- **间距**: `sm` (8px)
- **按钮高度**: 40px
- **图标大小**: `md` (20px)
- **文字大小**: `md` (12px)

**状态**:
- **正常**: `primary` 背景
- **悬停**: 加深 10%
- **禁用**: 透明度 50%
- **按下**: 加深 20%

**实现对照**:

VSCode:
```html
<div class="action-grid">
  <vscode-button appearance="primary">
    <span slot="start" class="codicon codicon-debug-start"></span>
    Launch App
  </vscode-button>
  <!-- more buttons -->
</div>

<style>
.action-grid {
  display: grid;
  grid-template-columns: 1fr 1fr;
  gap: 8px;
}
</style>
```

IntelliJ:
```kotlin
val actionPanel = panel {
  row {
    button("Launch App") {
      icon = AllIcons.Actions.Execute
      action { launchApp() }
    }.constraints(growX = true)
    
    button("Inspect") {
      icon = AllIcons.Actions.Find
      action { inspect() }
    }.constraints(growX = true)
  }
  row {
    button("Screenshot") {
      icon = AllIcons.Actions.Dump
      action { screenshot() }
    }.constraints(growX = true)
    
    button("Hot Reload") {
      icon = AllIcons.Actions.Refresh
      action { hotReload() }
    }.constraints(growX = true)
  }
}
```

### 5.3 元素列表项（Cross-Platform）

**规格**:
- **高度**: 最小 60px (自适应内容)
- **内边距**: `md` (12px)
- **悬停**: 背景变为 `hover`
- **选中**: 背景变为 `selection`

**内容结构**:
```
┌──────────────────────────────────┐
│ [Icon] element_name    [Badge]   │ ← Header
│ Type: Button • Pos: (x,y) • Size │ ← Details
│ [Tap] [Input] [Inspect]          │ ← Actions
└──────────────────────────────────┘
```

---

## 6. 交互流程

### 6.1 连接流程（统一）

```
┌─ User clicks "Launch App"
│
├─ 1. Show device selector
│    VSCode: Quick Pick
│    IntelliJ: Popup Menu
│
├─ 2. Execute flutter run
│    Both: Terminal with spinner
│
├─ 3. Parse VM Service URI
│    Both: Regex pattern match
│
├─ 4. Connect to VM Service
│    Both: WebSocket connection
│
├─ 5. Update UI
│    VSCode: Update Webview
│    IntelliJ: Update Swing components
│
└─ 6. Show success notification
     VSCode: vscode.window.showInformationMessage
     IntelliJ: Notifications.Bus.notify
```

### 6.2 错误处理流程（统一）

**统一的错误处理逻辑**:

```typescript
interface ErrorResponse {
  code: string;
  message: string;
  cause?: string;
  fixes: QuickFix[];
}

interface QuickFix {
  label: string;
  action: () => void;
  copyText?: string;
}

// 平台无关的错误处理
function handleConnectionError(error: Error): ErrorResponse {
  if (error.message.includes('DTD protocol')) {
    return {
      code: 'E301',
      message: 'Connection failed: DTD protocol detected',
      cause: 'Flutter 3.x uses DTD by default',
      fixes: [
        {
          label: 'Add --vm-service-port flag',
          copyText: 'flutter run --vm-service-port=50000',
          action: () => copyToClipboard(...)
        },
        {
          label: 'Restart with flag',
          action: () => restartWithFlag()
        }
      ]
    };
  }
  // ... more error patterns
}
```

**平台特定展示**:

VSCode:
```typescript
function showError(error: ErrorResponse) {
  const options = error.fixes.map(f => f.label);
  vscode.window.showErrorMessage(
    `${error.message}\n\n${error.cause || ''}`,
    ...options
  ).then(selected => {
    const fix = error.fixes.find(f => f.label === selected);
    if (fix) fix.action();
  });
}
```

IntelliJ:
```kotlin
fun showError(error: ErrorResponse) {
  val notification = Notification(
    "Flutter Skill",
    error.message,
    error.cause ?: "",
    NotificationType.ERROR
  )
  
  error.fixes.forEach { fix ->
    notification.addAction(object : AnAction(fix.label) {
      override fun actionPerformed(e: AnActionEvent) {
        fix.action()
      }
    })
  }
  
  Notifications.Bus.notify(notification, project)
}
```

---

## 7. 实现指南

### 7.1 共享代码架构

**核心逻辑层（Platform-Agnostic）**:

```
flutter_skill_core/
├── src/
│   ├── vm_service_client.dart    # VM Service 通信
│   ├── ui_inspector.dart          # UI 元素解析
│   ├── test_recorder.dart         # 测试记录
│   └── error_handler.dart         # 错误处理
└── pubspec.yaml
```

**平台适配层**:

VSCode:
```
vscode-extension/
├── src/
│   ├── bridge/
│   │   └── core_bridge.ts        # 调用 Dart 核心
│   ├── views/
│   │   ├── sidebar.ts            # 侧边栏视图
│   │   └── inspector.ts          # Inspector 面板
│   └── extension.ts
└── package.json
```

IntelliJ:
```
intellij-plugin/
├── src/
│   ├── bridge/
│   │   └── CoreBridge.kt         # 调用 Dart 核心
│   ├── toolwindow/
│   │   └── FlutterSkillPanel.kt  # 工具窗口
│   └── actions/
└── build.gradle.kts
```

### 7.2 主题适配策略

**VSCode 主题**:
```typescript
// 监听主题变化
vscode.window.onDidChangeActiveColorTheme((theme) => {
  updateWebviewTheme(theme.kind);
});

// 动态注入主题变量
function updateWebviewTheme(kind: ColorThemeKind) {
  webview.postMessage({
    command: 'updateTheme',
    theme: {
      kind: kind === ColorThemeKind.Dark ? 'dark' : 'light',
      colors: getCurrentThemeColors()
    }
  });
}
```

**IntelliJ 主题**:
```kotlin
// 监听主题变化
LafManager.getInstance().addLafManagerListener { 
  updatePanelTheme()
}

// 动态更新组件颜色
fun updatePanelTheme() {
  mainPanel.background = UIUtil.getPanelBackground()
  statusBadge.foreground = if (UIUtil.isUnderDarcula()) {
    JBColor.GREEN
  } else {
    JBColor.DARK_GRAY
  }
  mainPanel.repaint()
}
```

### 7.3 开发工作流

**并行开发策略**:

1. **共享设计资源**:
   - Figma/Sketch 设计文件
   - 统一的图标集（SVG）
   - 颜色系统文档

2. **独立开发**:
   - VSCode 团队实现 VSCode 版本
   - IntelliJ 团队实现 IntelliJ 版本
   - 共享核心 Dart 代码

3. **同步测试**:
   - 每周对齐功能
   - 跨平台 UI 审查
   - 用户体验一致性测试

4. **版本发布**:
   - 同步版本号
   - 同步发布时间
   - 统一的发布说明

---

## 8. 质量保证

### 8.1 一致性检查清单

**视觉一致性**:
- [ ] 相同的布局结构
- [ ] 相同的间距比例
- [ ] 相同的颜色语义
- [ ] 相同的图标含义
- [ ] 相同的文本内容

**功能一致性**:
- [ ] 相同的功能集合
- [ ] 相同的操作流程
- [ ] 相同的错误处理
- [ ] 相同的快捷键逻辑
- [ ] 相同的设置选项

**体验一致性**:
- [ ] 相同的响应时间
- [ ] 相同的加载状态
- [ ] 相同的反馈机制
- [ ] 相同的帮助文档

### 8.2 测试矩阵

| 测试项 | VSCode | IntelliJ | 预期结果 |
|-------|--------|----------|---------|
| 连接流程 | ✅ | ✅ | 相同步骤 |
| 错误提示 | ✅ | ✅ | 相同内容 |
| Inspector | ✅ | ✅ | 相同布局 |
| 快捷键 | ✅ | ✅ | 相同功能 |
| 浅色主题 | ✅ | ✅ | 颜色适配 |
| 深色主题 | ✅ | ✅ | 颜色适配 |

---

## 9. 参考资源

### VSCode
- [VSCode UX Guidelines](https://code.visualstudio.com/api/ux-guidelines/overview)
- [Codicons](https://microsoft.github.io/vscode-codicons/)
- [Webview UI Toolkit](https://github.com/microsoft/vscode-webview-ui-toolkit)

### IntelliJ IDEA
- [IntelliJ Platform UI Guidelines](https://jetbrains.design/intellij/)
- [IntelliJ Icons](https://jetbrains.design/intellij/resources/icons_list/)
- [IntelliJ UI DSL](https://plugins.jetbrains.com/docs/intellij/kotlin-ui-dsl.html)

### Design Systems
- [Material Design](https://material.io/design)
- [Fluent Design](https://www.microsoft.com/design/fluent/)
- [Human Interface Guidelines](https://developer.apple.com/design/human-interface-guidelines/)

---

**最后更新**: 2026-02-01
**版本**: 2.0 (跨平台统一版本)
**维护者**: Flutter Skill Team
