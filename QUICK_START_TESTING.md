# 🚀 Quick Start: 插件测试

快速上手 Flutter Skill VSCode 和 IntelliJ 插件的测试。

---

## ⚡ 一键准备测试环境

```bash
# 自动创建测试应用和准备环境
./scripts/setup_test_environment.sh
```

这会：
- ✅ 创建测试 Flutter 应用（带示例 Widget）
- ✅ 添加 flutter_skill 依赖
- ✅ 生成测试用的 main.dart
- ✅ 安装所有依赖

---

## 🔵 测试 VSCode 扩展（3 步）

### 1. 安装依赖并编译

```bash
cd vscode-extension
npm install
npm run compile
```

### 2. 启动调试

在 VSCode 中：
- 按 **F5** 键
- 或 **Run > Start Debugging**
- 新窗口（Extension Development Host）将打开

### 3. 运行测试应用

在 Extension Development Host 窗口中：

```bash
# 打开测试应用
File > Open Folder... > /tmp/flutter_skill_test_app

# 在终端运行应用
flutter run --vm-service-port=50000
```

**验证：**
- ✅ 侧边栏显示 "Flutter Skill"
- ✅ 连接状态显示 "Connected" 绿色徽章
- ✅ 点击 "Inspect" 看到元素列表
- ✅ 点击 "Tap" 测试按钮交互

---

## 🟢 测试 IntelliJ 插件（2 步）

### 1. 运行开发沙箱

```bash
cd intellij-plugin
./gradlew runIde
```

等待新的 IntelliJ 窗口启动（首次会下载 IDE，需要几分钟）

### 2. 打开测试应用

在新的 IntelliJ 窗口中：

```bash
# 打开项目
File > Open... > /tmp/flutter_skill_test_app

# 在终端运行应用
flutter run --vm-service-port=50000
```

**验证：**
- ✅ 右侧工具栏显示 "Flutter Skill"
- ✅ Tool Window 显示 5 个卡片区域
- ✅ 连接状态显示 "Connected"
- ✅ 点击 "Inspect" 看到元素树
- ✅ 选择元素，点击 "Tap" 测试交互

---

## 🧪 核心测试清单（5 分钟）

### ✅ 1. 连接状态
- [ ] 显示绿色 "Connected" 徽章
- [ ] 显示端口 50000

### ✅ 2. Inspect 功能
- [ ] 点击 "Inspect" 按钮
- [ ] 看到元素列表/树（10+ 元素）
- [ ] 搜索 "button" 过滤结果

### ✅ 3. Tap 操作
- [ ] 选择 "primary_button"
- [ ] 点击 "Tap"
- [ ] Flutter 应用显示 "Primary Button Tapped!"

### ✅ 4. 文本输入
- [ ] 选择 "text_field"
- [ ] 点击 "Input"
- [ ] 输入 "Hello"
- [ ] Flutter 应用文本框显示内容

### ✅ 5. Screenshot
- [ ] 点击 "Screenshot"
- [ ] 保存 PNG 文件
- [ ] 打开验证截图正确

### ✅ 6. Hot Reload
- [ ] 修改 main.dart 中的文本
- [ ] 点击 "Hot Reload"
- [ ] Flutter 应用刷新显示更改

---

## 📱 测试应用 Widget 说明

测试应用包含以下带 Key 的 Widget：

| Widget Key | 类型 | 用途 |
|-----------|------|------|
| `display_text` | Text | 显示操作结果 |
| `primary_button` | ElevatedButton | 测试 Tap |
| `secondary_button` | OutlinedButton | 测试 Tap |
| `icon_button` | IconButton | 测试图标按钮 |
| `text_field` | TextField | 测试文本输入 |
| `submit_button` | ElevatedButton | 提交文本 |
| `counter_text` | Text | 计数器显示 |
| `increment_button` | ElevatedButton | 增加计数 |
| `decrement_button` | ElevatedButton | 减少计数 |
| `fab` | FloatingActionButton | 测试 FAB |

---

## 🐛 常见问题

### Q: VSCode 扩展无法连接？

**A:** 检查：
1. Flutter 应用是否运行？`flutter devices`
2. 是否使用了 `--vm-service-port=50000`？
3. `.flutter_skill_uri` 文件是否存在？`cat .flutter_skill_uri`

### Q: IntelliJ 显示 "No Flutter app connected"？

**A:**
1. 点击 "Refresh" 按钮重新扫描
2. 确认 Flutter 应用正在运行
3. 查看 `Help > Show Log` 获取详细日志

### Q: Inspect 返回空列表？

**A:** 确保 main.dart 包含：
```dart
import 'package:flutter_skill/flutter_skill.dart';

void main() {
  FlutterSkillBinding.ensureInitialized();  // ← 必须添加
  runApp(const MyApp());
}
```

### Q: 如何查看调试日志？

**VSCode:**
- **Output** 面板 > 选择 "Flutter Skill"

**IntelliJ:**
- **Help > Show Log in Finder/Explorer**
- 查看 `idea.log`

---

## 📚 详细文档

更多详细测试指南：
- **完整测试文档:** [docs/PLUGIN_TESTING_GUIDE.md](docs/PLUGIN_TESTING_GUIDE.md)
- **测试报告模板:** [docs/TESTING_REPORT_v0.4.1.md](docs/TESTING_REPORT_v0.4.1.md)

---

## 🎯 下一步

测试完成后：
1. ✅ 填写测试报告（见 PLUGIN_TESTING_GUIDE.md）
2. ✅ 提交 Issue 报告问题
3. ✅ 分享你的测试结果

**Happy Testing! 🚀**

---

**需要帮助？**
- GitHub Issues: https://github.com/ai-dashboad/flutter-skill/issues
- 完整文档: https://github.com/ai-dashboad/flutter-skill
