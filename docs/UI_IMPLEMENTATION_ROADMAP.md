# Flutter Skill UI 改进实施路线图

> **跨平台统一开发计划** - VSCode & IntelliJ IDEA 并行实施

## 📅 总体时间线: 8 周（两个平台并行）

### 团队分工
- **VSCode 团队**: 负责 VSCode Extension 实现
- **IntelliJ 团队**: 负责 IntelliJ Plugin 实现
- **Core 团队**: 负责共享核心逻辑（Dart）
- **设计团队**: 负责跨平台设计审查

### 同步节点
- **每周五**: 跨平台进度同步会议
- **每两周**: UI/UX 一致性审查
- **每月**: 用户测试和反馈收集

---

## Week 1-2: 基础改进 🏗️

### 目标
快速优化现有界面，立即改善用户体验

### 任务清单

#### 1.1 状态栏集成
- [ ] 在 VSCode 状态栏添加 Flutter Skill 指示器
- [ ] 显示连接状态（已连接/未连接/连接中）
- [ ] 点击状态栏打开快捷操作
- [ ] 添加设备名称显示

**文件**: `vscode-extension/src/statusBar.ts`

```typescript
export class FlutterSkillStatusBar {
  private statusBarItem: vscode.StatusBarItem;

  constructor() {
    this.statusBarItem = vscode.window.createStatusBarItem(
      vscode.StatusBarAlignment.Left,
      100
    );
    this.statusBarItem.command = 'flutter-skill.showQuickActions';
    this.update('disconnected');
  }

  update(status: 'connected' | 'disconnected' | 'connecting', device?: string) {
    const icons = {
      connected: '$(debug-alt)',
      disconnected: '$(debug-disconnect)',
      connecting: '$(loading~spin)'
    };

    const labels = {
      connected: `Flutter: ${device || 'Connected'}`,
      disconnected: 'Flutter: Disconnected',
      connecting: 'Flutter: Connecting...'
    };

    this.statusBarItem.text = `${icons[status]} ${labels[status]}`;
    this.statusBarItem.show();
  }
}
```

#### 1.2 连接状态卡片
- [ ] 创建可视化连接状态卡片
- [ ] 添加设备信息显示
- [ ] 添加 VM Service 端口信息
- [ ] 实现断开连接/刷新按钮

**预览**:
```
╔═══ Connection Status ═══╗
║  🟢 Connected            ║
║  📱 iPhone 16 Pro        ║
║  ⚡ VM Service: :50000   ║
║  [Disconnect] [Refresh]  ║
╚══════════════════════════╝
```

#### 1.3 错误提示优化
- [ ] 替换简单的错误弹窗
- [ ] 添加详细错误原因说明
- [ ] 提供快速修复建议
- [ ] 添加"查看完整指南"链接

**示例**:
```typescript
function showConnectionError(error: Error) {
  const quickFixes = [
    {
      label: '⚡ Add --vm-service-port flag',
      action: () => {
        vscode.env.clipboard.writeText('flutter run --vm-service-port=50000');
        vscode.window.showInformationMessage('Command copied to clipboard!');
      }
    },
    {
      label: '🔄 Restart with flag',
      action: () => restartAppWithFlag()
    }
  ];

  vscode.window.showErrorMessage(
    `Connection failed: ${error.message}`,
    ...quickFixes.map(f => f.label)
  ).then(selected => {
    const fix = quickFixes.find(f => f.label === selected);
    if (fix) fix.action();
  });
}
```

#### 1.4 按钮分组和图标
- [ ] 将操作按钮分组（Launch, Inspect, Screenshot, etc.）
- [ ] 使用 VSCode Codicons
- [ ] 添加工具提示（tooltip）
- [ ] 实现按钮禁用状态

**完成标准**:
- ✅ 状态栏显示正确的连接状态
- ✅ 错误提示包含解决方案
- ✅ 所有按钮都有合适的图标和提示
- ✅ 视觉层次清晰

---

## Week 3-4: 核心功能 🎯

### 目标
实现核心交互功能，提升工作效率

### 任务清单

#### 2.1 Inspector Webview
- [ ] 创建独立的 Inspector Webview 面板
- [ ] 显示应用截图
- [ ] 支持元素高亮
- [ ] 实现点击截图定位元素

**文件**: `vscode-extension/src/views/InspectorView.ts`

```typescript
export class InspectorView {
  private panel: vscode.WebviewPanel | undefined;

  show(elements: UIElement[], screenshot: string) {
    if (!this.panel) {
      this.panel = vscode.window.createWebviewPanel(
        'flutterSkillInspector',
        'Flutter UI Inspector',
        vscode.ViewColumn.Two,
        { enableScripts: true }
      );
    }

    this.panel.webview.html = this.getHtmlContent(elements, screenshot);
    this.panel.reveal();
  }

  private getHtmlContent(elements: UIElement[], screenshot: string) {
    return `
      <!DOCTYPE html>
      <html>
        <body>
          <div class="screenshot-container">
            <img src="${screenshot}" id="appScreenshot" />
            <canvas id="highlightCanvas"></canvas>
          </div>
          <div class="elements-list">
            ${elements.map(e => this.renderElement(e)).join('')}
          </div>
        </body>
      </html>
    `;
  }
}
```

#### 2.2 Interactive Elements 列表
- [ ] 显示所有可交互元素
- [ ] 按类型分组（Button, TextField, etc.）
- [ ] 显示元素属性（位置、大小、文本）
- [ ] 实现搜索过滤

**UI 组件**:
```html
<div class="element-item">
  <div class="element-header">
    <span class="element-icon">🔘</span>
    <span class="element-name">login_button</span>
    <span class="element-type">ElevatedButton</span>
  </div>
  <div class="element-details">
    Text: "Login" • Position: (156, 420) • Size: 120×48
  </div>
  <div class="element-actions">
    <button onclick="tap('login_button')">👆 Tap</button>
    <button onclick="inspect('login_button')">🔍 Inspect</button>
  </div>
</div>
```

#### 2.3 Quick Actions 面板
- [ ] 实现快速操作面板
- [ ] 添加常用操作快捷键
- [ ] 支持自定义操作
- [ ] 保存最近使用的操作

**快捷键**:
```json
{
  "keybindings": [
    {
      "command": "flutter-skill.launchApp",
      "key": "ctrl+shift+f l",
      "mac": "cmd+shift+f l"
    },
    {
      "command": "flutter-skill.inspect",
      "key": "ctrl+shift+f i",
      "mac": "cmd+shift+f i"
    },
    {
      "command": "flutter-skill.screenshot",
      "key": "ctrl+shift+f s",
      "mac": "cmd+shift+f s"
    }
  ]
}
```

#### 2.4 Onboarding 流程
- [ ] 首次启动显示欢迎页面
- [ ] 引导用户完成基本设置
- [ ] 提供快速入门教程
- [ ] 添加示例项目链接

**完成标准**:
- ✅ Inspector 可以显示截图和元素
- ✅ 元素列表可以筛选和搜索
- ✅ 快捷键正常工作
- ✅ 新用户能在 2 分钟内完成首次测试

---

## Week 5-6: 高级功能 🚀

### 目标
添加高级功能，满足专业用户需求

### 任务清单

#### 3.1 Test Builder
- [ ] 创建可视化测试构建器
- [ ] 支持拖拽添加测试步骤
- [ ] 生成测试代码
- [ ] 保存和加载测试用例

**数据结构**:
```typescript
interface TestStep {
  type: 'tap' | 'input' | 'wait' | 'screenshot' | 'assert';
  target?: string;
  value?: any;
  timeout?: number;
}

interface TestCase {
  id: string;
  name: string;
  steps: TestStep[];
  createdAt: Date;
}
```

**UI 示例**:
```
┌─── Test Builder ───┐
│ Test: Login Flow   │
│                    │
│ 1. [👆] Tap         │
│    email_field     │
│    [▶️] [✕]         │
│                    │
│ 2. [⌨️] Input       │
│    "test@test.com" │
│    [▶️] [✕]         │
│                    │
│ [+ Add Step]       │
│ [▶️ Run] [💾 Save]  │
└────────────────────┘
```

#### 3.2 Logs Viewer
- [ ] 实时显示应用日志
- [ ] 支持日志过滤（Info/Warn/Error）
- [ ] 支持搜索和高亮
- [ ] 导出日志功能

**实现**:
```typescript
export class LogsViewer {
  private logs: LogEntry[] = [];

  addLog(entry: LogEntry) {
    this.logs.push(entry);
    this.updateView();

    // Auto-scroll to bottom
    if (this.autoScroll) {
      this.scrollToBottom();
    }
  }

  filter(level: 'all' | 'info' | 'warn' | 'error') {
    const filtered = this.logs.filter(log =>
      level === 'all' || log.level === level
    );
    this.updateView(filtered);
  }

  search(query: string) {
    const results = this.logs.filter(log =>
      log.message.toLowerCase().includes(query.toLowerCase())
    );
    this.updateView(results);
  }
}
```

#### 3.3 History Tracking
- [ ] 记录所有测试操作
- [ ] 显示操作时间线
- [ ] 支持重放历史操作
- [ ] 导出测试报告

**数据模型**:
```typescript
interface HistoryEntry {
  id: string;
  type: 'tap' | 'input' | 'screenshot' | 'inspect';
  timestamp: Date;
  target?: string;
  result: 'success' | 'error';
  duration: number;
  metadata?: any;
}
```

#### 3.4 设置界面
- [ ] 创建设置页面
- [ ] 支持默认设备选择
- [ ] 配置截图质量
- [ ] 自定义快捷键

**设置项**:
```typescript
interface FlutterSkillSettings {
  defaultDevice: string | null;
  vmServicePort: number;
  screenshotQuality: number; // 0-1
  autoLaunchOnStartup: boolean;
  autoReloadOnSave: boolean;
  showNotifications: boolean;
  logLevel: 'debug' | 'info' | 'warn' | 'error';
}
```

**完成标准**:
- ✅ Test Builder 可以创建和运行测试
- ✅ Logs Viewer 实时显示日志
- ✅ History 记录所有操作
- ✅ 设置可以持久化保存

---

## Week 7-8: 打磨优化 ✨

### 目标
优化性能和用户体验细节

### 任务清单

#### 4.1 动画和过渡
- [ ] 添加页面切换动画
- [ ] 元素进入/退出动画
- [ ] Loading 状态动画
- [ ] 支持动画禁用选项

**CSS 动画**:
```css
/* 淡入动画 */
@keyframes fadeIn {
  from {
    opacity: 0;
    transform: translateY(-10px);
  }
  to {
    opacity: 1;
    transform: translateY(0);
  }
}

.element-item {
  animation: fadeIn 0.3s ease-out;
}

/* 尊重用户偏好 */
@media (prefers-reduced-motion: reduce) {
  * {
    animation: none !important;
    transition: none !important;
  }
}
```

#### 4.2 快捷键支持
- [ ] 为所有主要功能添加快捷键
- [ ] 显示快捷键提示
- [ ] 支持自定义快捷键
- [ ] 添加快捷键列表页面

**快捷键列表**:
| 功能 | Windows/Linux | macOS |
|-----|--------------|-------|
| Launch App | Ctrl+Shift+F L | Cmd+Shift+F L |
| Inspect | Ctrl+Shift+F I | Cmd+Shift+F I |
| Screenshot | Ctrl+Shift+F S | Cmd+Shift+F S |
| Hot Reload | Ctrl+Shift+F R | Cmd+Shift+F R |

#### 4.3 主题适配
- [ ] 完整支持 VSCode 主题变量
- [ ] 测试浅色/深色/高对比度主题
- [ ] 添加自定义颜色配置
- [ ] 优化图标在不同主题下的显示

**主题测试清单**:
- [ ] Light (Default Light+)
- [ ] Dark (Default Dark+)
- [ ] High Contrast Light
- [ ] High Contrast Dark
- [ ] Popular themes (One Dark Pro, Dracula, etc.)

#### 4.4 性能优化
- [ ] 优化元素列表渲染（虚拟滚动）
- [ ] 优化截图加载（懒加载）
- [ ] 减少不必要的重渲染
- [ ] 添加性能监控

**虚拟滚动实现**:
```typescript
import { VirtualScroller } from '@vscode/virtual-scroller';

const scroller = new VirtualScroller({
  itemHeight: 80,
  items: elements,
  renderItem: (element) => renderElementCard(element)
});
```

**完成标准**:
- ✅ 所有动画流畅（60fps）
- ✅ 快捷键响应时间 < 100ms
- ✅ 支持所有 VSCode 官方主题
- ✅ 1000+ 元素列表滚动流畅

---

## 📊 验收标准

### Phase 1 完成标准
- [ ] 状态栏正确显示连接状态
- [ ] 错误提示包含解决方案
- [ ] 所有按钮有图标和tooltip
- [ ] 通过 5 个用户测试

### Phase 2 完成标准
- [ ] Inspector 显示截图和元素列表
- [ ] 支持点击元素执行操作
- [ ] 新用户 2 分钟内完成首次测试
- [ ] 通过 10 个用户测试

### Phase 3 完成标准
- [ ] Test Builder 可以创建测试用例
- [ ] Logs Viewer 实时显示日志
- [ ] History 记录所有操作
- [ ] 专业用户认可度 > 90%

### Phase 4 完成标准
- [ ] 所有主题显示正常
- [ ] 性能达标（60fps, < 100ms响应）
- [ ] 无障碍功能完整
- [ ] 通过 20+ 用户测试

---

## 🎯 成功指标

### 用户体验指标
- ⏱️ 首次连接时间 < 10秒
- 🎯 新用户完成首次测试 < 2分钟
- 📊 错误自助解决率 > 80%
- ⭐ 用户满意度 > 4.5/5

### 技术指标
- 🚀 UI 响应时间 < 100ms
- 📱 支持 1000+ 元素流畅滚动
- 🎨 所有官方主题兼容
- ♿ 通过 WCAG 2.1 AA 标准

---

## 📝 每周检查点

### Week 1 检查点
- [ ] 状态栏集成完成
- [ ] 错误提示优化完成
- [ ] 基础 UI 改进完成

### Week 3 检查点
- [ ] Inspector Webview 完成
- [ ] Interactive Elements 列表完成
- [ ] Onboarding 流程完成

### Week 5 检查点
- [ ] Test Builder 完成
- [ ] Logs Viewer 完成
- [ ] Settings 界面完成

### Week 7 检查点
- [ ] 所有动画完成
- [ ] 主题适配完成
- [ ] 性能优化完成

---

## 🚀 启动项目

### 1. 创建功能分支
```bash
git checkout -b feature/ui-improvements
```

### 2. 安装依赖
```bash
cd vscode-extension
npm install @vscode/webview-ui-toolkit
npm install @vscode/codicons
```

### 3. 开发环境设置
```bash
# 启动开发模式
npm run watch

# 在 VSCode 中按 F5 启动调试
```

### 4. 提交规范
```bash
# 遵循 Conventional Commits
git commit -m "feat(ui): add status bar integration"
git commit -m "style(ui): improve button layout"
git commit -m "docs(ui): update design guide"
```

---

## 📞 获取帮助

- **设计问题**: 参考 `UI_UX_DESIGN_GUIDE.md`
- **技术问题**: 查看 VSCode Extension API 文档
- **用户反馈**: 创建 GitHub Discussion

---

**开始日期**: TBD
**预计完成**: 8 周后
**负责人**: Flutter Skill Team

## 🔄 跨平台开发原则

### 设计一致性
- ✅ **相同的功能集** - 两个平台提供相同的功能
- ✅ **相同的布局** - 统一的信息架构和视觉层次
- ✅ **相同的交互** - 统一的操作流程
- ⚠️ **平台适配** - 遵循各平台的原生体验

### 开发策略
1. **设计优先** - 先统一设计，再分平台实现
2. **核心共享** - VM Service 通信等核心逻辑共享
3. **并行开发** - 两个平台同时开发，每周同步
4. **统一测试** - 使用相同的测试用例

---

## Phase 0: 准备阶段 (Week 0)

### 目标
建立跨平台开发基础设施

### Core 团队任务
- [ ] 创建 `flutter_skill_core` Dart 包
- [ ] 定义平台无关的接口
- [ ] 实现 VM Service Client
- [ ] 编写核心逻辑单元测试

### 设计团队任务
- [ ] 创建 Figma 设计文件
- [ ] 定义设计 Token（颜色、间距、字体）
- [ ] 制作图标集（SVG）
- [ ] 编写设计规范文档

### VSCode 团队任务
- [ ] 设置项目结构
- [ ] 配置构建工具
- [ ] 集成核心 Dart 包
- [ ] 创建基础 Webview 模板

### IntelliJ 团队任务
- [ ] 设置项目结构
- [ ] 配置 Gradle 构建
- [ ] 集成核心 Dart 包
- [ ] 创建基础 Tool Window

### 验收标准
- ✅ 两个平台都能调用核心 Dart 代码
- ✅ 设计规范文档完成
- ✅ 开发环境配置完成

---

## Week 1-2: 基础改进 🏗️

### 核心目标
快速优化现有界面，立即改善用户体验

---

### 共享任务（Core 团队）

#### 状态管理
- [ ] 定义连接状态接口
```dart
enum ConnectionStatus { connected, disconnected, connecting, error }

class ConnectionState {
  final ConnectionStatus status;
  final String? deviceName;
  final int? vmServicePort;
  final String? errorMessage;
}
```

- [ ] 实现状态变更通知机制
- [ ] 编写状态转换逻辑测试

---

### VSCode 团队任务

#### 1.1 状态栏集成
**文件**: `vscode-extension/src/statusBar.ts`

- [ ] 创建 StatusBarItem
- [ ] 实现状态更新逻辑
- [ ] 添加点击打开 Quick Actions
- [ ] 支持主题颜色适配

**代码示例**:
```typescript
export class FlutterSkillStatusBar {
  private statusBarItem: vscode.StatusBarItem;

  constructor() {
    this.statusBarItem = vscode.window.createStatusBarItem(
      vscode.StatusBarAlignment.Left,
      100
    );
    this.statusBarItem.command = 'flutter-skill.showQuickActions';
    this.update('disconnected');
  }

  update(status: ConnectionStatus, device?: string) {
    const icons = {
      connected: '$(debug-alt)',
      disconnected: '$(debug-disconnect)',
      connecting: '$(loading~spin)'
    };
    
    const labels = {
      connected: `Flutter: ${device || 'Connected'}`,
      disconnected: 'Flutter: Disconnected',
      connecting: 'Flutter: Connecting...'
    };

    this.statusBarItem.text = `${icons[status]} ${labels[status]}`;
    this.statusBarItem.show();
  }
}
```

#### 1.2 连接状态卡片
**文件**: `vscode-extension/src/views/statusCard.html`

- [ ] 设计卡片 HTML/CSS
- [ ] 实现状态徽章组件
- [ ] 添加设备信息显示
- [ ] 实现断开/刷新按钮

#### 1.3 错误提示优化
**文件**: `vscode-extension/src/errorHandler.ts`

- [ ] 创建错误处理器
- [ ] 实现快速修复建议
- [ ] 添加复制命令功能
- [ ] 集成帮助文档链接

---

### IntelliJ 团队任务

#### 1.1 状态栏 Widget
**文件**: `intellij-plugin/src/main/kotlin/com/flutter/skill/statusbar/FlutterSkillStatusWidget.kt`

- [ ] 创建 StatusBarWidget
- [ ] 实现状态更新逻辑
- [ ] 添加点击打开 Tool Window
- [ ] 支持主题颜色适配

**代码示例**:
```kotlin
class FlutterSkillStatusWidget(private val project: Project) : StatusBarWidget {
  private var status: ConnectionStatus = ConnectionStatus.DISCONNECTED
  
  override fun getPresentation(): StatusBarWidget.WidgetPresentation {
    return object : StatusBarWidget.TextPresentation {
      override fun getText(): String {
        return when (status) {
          ConnectionStatus.CONNECTED -> "Flutter: Connected"
          ConnectionStatus.DISCONNECTED -> "Flutter: Disconnected"
          ConnectionStatus.CONNECTING -> "Flutter: Connecting..."
          ConnectionStatus.ERROR -> "Flutter: Error"
        }
      }
      
      override fun getIcon(): Icon? {
        return when (status) {
          ConnectionStatus.CONNECTED -> AllIcons.Debugger.ThreadAtBreakpoint
          ConnectionStatus.DISCONNECTED -> AllIcons.Debugger.ThreadSuspended
          ConnectionStatus.CONNECTING -> AnimatedIcon.Default.getInstance()
          ConnectionStatus.ERROR -> AllIcons.General.Error
        }
      }
    }
  }
}
```

#### 1.2 连接状态面板
**文件**: `intellij-plugin/src/main/kotlin/com/flutter/skill/ui/StatusPanel.kt`

- [ ] 使用 UI DSL 创建状态面板
- [ ] 实现状态徽章组件
- [ ] 添加设备信息显示
- [ ] 实现断开/刷新按钮

**UI DSL 示例**:
```kotlin
class StatusPanel : JPanel() {
  init {
    layout = BorderLayout()
    
    val panel = panel {
      border = JBUI.Borders.customLine(borderColor, 1)
      background = UIUtil.getPanelBackground()
      
      titledRow("Connection Status") {
        row {
          icon(AllIcons.Debugger.ThreadAtBreakpoint)
          label("Connected") {
            foreground = FileStatus.ADDED.color
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
    }
    
    add(panel, BorderLayout.CENTER)
  }
}
```

#### 1.3 错误通知
**文件**: `intellij-plugin/src/main/kotlin/com/flutter/skill/ErrorNotifier.kt`

- [ ] 创建错误通知器
- [ ] 实现快速修复 Actions
- [ ] 添加复制命令功能
- [ ] 集成帮助文档链接

```kotlin
object ErrorNotifier {
  fun showConnectionError(project: Project, error: ConnectionError) {
    val notification = Notification(
      "Flutter Skill",
      "Connection Failed",
      error.message,
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
}
```

---

### 设计团队审查清单（Week 1-2）

**视觉一致性检查**:
- [ ] 状态栏图标在两个平台含义相同
- [ ] 连接状态卡片布局一致
- [ ] 颜色使用符合设计规范
- [ ] 间距比例一致

**交互一致性检查**:
- [ ] 点击状态栏行为一致
- [ ] 错误提示内容一致
- [ ] 快速修复选项一致

### 完成标准（Week 1-2）
- ✅ **VSCode**: 状态栏正确显示连接状态
- ✅ **IntelliJ**: 状态栏 Widget 正确显示连接状态
- ✅ **Both**: 错误提示包含解决方案
- ✅ **Both**: 所有按钮都有合适的图标和提示
- ✅ **Consistency**: 通过设计团队审查
- ✅ **Testing**: 通过 5 个用户跨平台测试

---

## Week 3-4: 核心功能 🎯

### 核心目标
实现核心交互功能，提升工作效率

---

### 共享任务（Core 团队）

#### UI 元素模型
- [ ] 定义元素接口
```dart
class UIElement {
  final String key;
  final String type;
  final String? text;
  final Rect bounds;
  final Point center;
  final bool enabled;
  final Map<String, dynamic> properties;
}
```

- [ ] 实现元素树解析
- [ ] 添加元素筛选和搜索
- [ ] 编写元素操作 API

---

### VSCode 团队任务

#### 2.1 Inspector Webview
**文件**: `vscode-extension/src/views/InspectorView.ts`

- [ ] 创建 Webview Panel
- [ ] 实现截图显示
- [ ] 添加元素高亮层
- [ ] 支持点击定位元素

**实现示例**:
```typescript
export class InspectorView {
  private panel: vscode.WebviewPanel | undefined;

  show(elements: UIElement[], screenshot: string) {
    if (!this.panel) {
      this.panel = vscode.window.createWebviewPanel(
        'flutterSkillInspector',
        'Flutter UI Inspector',
        vscode.ViewColumn.Two,
        {
          enableScripts: true,
          retainContextWhenHidden: true
        }
      );
    }

    this.panel.webview.html = this.getHtmlContent(elements, screenshot);
    this.panel.reveal();
    
    // Handle messages from webview
    this.panel.webview.onDidReceiveMessage(
      message => this.handleWebviewMessage(message)
    );
  }
}
```

#### 2.2 Interactive Elements 列表
**文件**: `vscode-extension/src/views/elementsTree.ts`

- [ ] 创建 TreeDataProvider
- [ ] 实现元素树视图
- [ ] 添加搜索过滤
- [ ] 支持元素操作（Tap/Input/Inspect）

---

### IntelliJ 团队任务

#### 2.1 Inspector Tool Window
**文件**: `intellij-plugin/src/main/kotlin/com/flutter/skill/inspector/InspectorPanel.kt`

- [ ] 创建 Inspector Panel
- [ ] 使用 JLabel 显示截图
- [ ] 添加 Canvas 高亮层
- [ ] 支持点击定位元素

**实现示例**:
```kotlin
class InspectorPanel(private val project: Project) : JPanel() {
  private val screenshotLabel = JLabel()
  private val highlightCanvas = HighlightCanvas()
  
  init {
    layout = BorderLayout()
    
    val screenshotPanel = JLayeredPane().apply {
      add(screenshotLabel, JLayeredPane.DEFAULT_LAYER)
      add(highlightCanvas, JLayeredPane.PALETTE_LAYER)
    }
    
    add(screenshotPanel, BorderLayout.CENTER)
    add(createElementsPanel(), BorderLayout.EAST)
    
    // Handle mouse clicks
    screenshotLabel.addMouseListener(object : MouseAdapter() {
      override fun mouseClicked(e: MouseEvent) {
        handleScreenshotClick(e.point)
      }
    })
  }
}
```

#### 2.2 Elements Tree
**文件**: `intellij-plugin/src/main/kotlin/com/flutter/skill/tree/ElementsTree.kt`

- [ ] 创建 TreeModel
- [ ] 实现 JTree 视图
- [ ] 添加搜索过滤
- [ ] 支持右键菜单操作

```kotlin
class ElementsTreeModel(private val elements: List<UIElement>) : DefaultTreeModel(null) {
  init {
    root = buildTree(elements)
  }
  
  private fun buildTree(elements: List<UIElement>): DefaultMutableTreeNode {
    val root = DefaultMutableTreeNode("App")
    elements.forEach { element ->
      val node = DefaultMutableTreeNode(element)
      root.add(node)
    }
    return root
  }
}
```

---

### 并行开发对齐

#### 功能对照表
| 功能 | VSCode 实现 | IntelliJ 实现 | 统一接口 |
|-----|-----------|--------------|---------|
| **Inspector** | Webview Panel | Tool Window | `showInspector(elements, screenshot)` |
| **元素列表** | TreeView | JTree | `updateElements(elements[])` |
| **截图显示** | `<img>` tag | JLabel | `showScreenshot(base64)` |
| **元素高亮** | Canvas overlay | Canvas layer | `highlightElement(bounds)` |
| **搜索** | Input filter | JTextField filter | `searchElements(query)` |

### 完成标准（Week 3-4）
- ✅ **VSCode**: Inspector 显示截图和元素列表
- ✅ **IntelliJ**: Inspector 显示截图和元素列表
- ✅ **Both**: 支持点击元素执行操作
- ✅ **Both**: 支持搜索和过滤
- ✅ **Consistency**: UI 布局一致性审查通过
- ✅ **Testing**: 新用户 2 分钟内完成首次测试

---

## Week 5-6: 高级功能 🚀

### 共享任务（Core 团队）

#### Test Recording
- [ ] 实现测试步骤记录
```dart
class TestStep {
  final String type; // tap, input, wait, screenshot
  final String? target;
  final dynamic value;
  final int? timeout;
}

class TestRecorder {
  final List<TestStep> steps = [];
  
  void recordTap(String key) {
    steps.add(TestStep(type: 'tap', target: key));
  }
  
  void recordInput(String key, String text) {
    steps.add(TestStep(type: 'input', target: key, value: text));
  }
  
  String generateCode() {
    // Generate test code from steps
  }
}
```

---

### VSCode 团队任务

#### 3.1 Test Builder
- [ ] 创建 Test Builder Webview
- [ ] 实现拖拽步骤
- [ ] 生成测试代码
- [ ] 保存/加载测试用例

#### 3.2 Logs Viewer
- [ ] 集成 Output Channel
- [ ] 实现日志过滤
- [ ] 添加搜索功能
- [ ] 支持日志导出

---

### IntelliJ 团队任务

#### 3.1 Test Builder
- [ ] 创建 Test Builder Dialog
- [ ] 使用 Table 显示步骤
- [ ] 生成测试代码
- [ ] 保存/加载测试用例

#### 3.2 Logs Viewer
- [ ] 集成 Console View
- [ ] 实现日志过滤
- [ ] 添加搜索功能
- [ ] 支持日志导出

---

## 🎯 跨平台验收标准

### 功能完整性
- [ ] 两个平台提供相同的功能
- [ ] 核心操作流程一致
- [ ] 错误处理逻辑一致

### UI 一致性
- [ ] 布局结构相同
- [ ] 颜色语义一致
- [ ] 图标含义一致
- [ ] 文本内容相同

### 用户体验
- [ ] 响应时间相近（±20ms）
- [ ] 加载状态一致
- [ ] 通知内容一致
- [ ] 帮助文档统一

---

## 📊 成功指标（跨平台）

### 用户体验指标
| 指标 | 目标 | VSCode | IntelliJ |
|-----|------|--------|----------|
| 首次连接时间 | < 10s | ⏱️ | ⏱️ |
| 新用户首次测试 | < 2min | 🎯 | 🎯 |
| 错误自助解决率 | > 80% | 📊 | 📊 |
| 用户满意度 | > 4.5/5 | ⭐ | ⭐ |

### 一致性指标
- **视觉一致性**: > 95% (设计审查)
- **功能一致性**: 100% (功能集合)
- **体验一致性**: > 90% (用户测试)

---

## 🔄 同步开发流程

### 每日同步
- 晨会（15分钟）
- 更新进度到共享看板
- 标记阻塞问题

### 每周同步
- **周三**: 技术同步会（1小时）
  - 演示本周进度
  - 讨论技术难点
  - 对齐下周计划
  
- **周五**: 设计审查会（1小时）
  - UI 一致性检查
  - 用户体验评审
  - 收集改进建议

### 每两周同步
- **Sprint Review**: 演示完成功能
- **User Testing**: 用户测试会（两个平台）
- **Retrospective**: 回顾和改进

---

**最后更新**: 2026-02-01
**版本**: 2.0 (跨平台版本)
**负责人**: Flutter Skill Team (VSCode + IntelliJ + Core + Design)
