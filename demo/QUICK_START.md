# 快速开始 - 测试可视化指示器

## 🎯 最简单的方法：使用现有的 Flutter 项目

你不需要创建新项目！可以直接在任何现有的 Flutter 应用中测试可视化指示器。

### 方法 1: 使用你自己的 Flutter 项目 ⭐

```bash
# 1. 进入你的 Flutter 项目
cd /path/to/your/flutter/project

# 2. 添加 flutter_skill 依赖
flutter pub add flutter_skill

# 3. 在 main.dart 顶部添加
import 'package:flutter_skill/flutter_skill.dart';

# 4. 在 main() 函数开始处添加
void main() {
  FlutterSkillBinding.ensureInitialized();  // 添加这行
  runApp(MyApp());
}

# 5. 运行你的应用
flutter run -d "iPhone 16 Pro" --vm-service-port=50000
```

现在你的应用已经支持可视化指示器了！

### 方法 2: 创建最小测试项目

```bash
cd /Users/cw/development/flutter-skill

# 创建一个新的 Flutter 项目
flutter create demo_app
cd demo_app

# 添加 flutter_skill（使用本地路径）
flutter pub add flutter_skill --path=..

# 替换 lib/main.dart
cat > lib/main.dart << 'EOF'
import 'package:flutter/material.dart';
import 'package:flutter_skill/flutter_skill.dart';

void main() {
  FlutterSkillBinding.ensureInitialized();
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Flutter Skill Visual Demo',
      theme: ThemeData(primarySwatch: Colors.blue),
      home: const HomePage(),
    );
  }
}

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  final _textController = TextEditingController();
  String _status = 'Ready';

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Visual Indicators Test')),
      body: Padding(
        padding: const EdgeInsets.all(20.0),
        child: Column(
          children: [
            // Status display
            Container(
              padding: const EdgeInsets.all(16),
              color: Colors.blue[50],
              child: Text(_status, style: const TextStyle(fontSize: 18)),
            ),
            const SizedBox(height: 20),

            // Tap test buttons
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: [
                ElevatedButton(
                  key: const Key('btn1'),
                  onPressed: () => setState(() => _status = 'Button 1 clicked'),
                  child: const Text('Button 1'),
                ),
                ElevatedButton(
                  key: const Key('btn2'),
                  onPressed: () => setState(() => _status = 'Button 2 clicked'),
                  child: const Text('Button 2'),
                ),
              ],
            ),
            const SizedBox(height: 20),

            // Text input
            TextField(
              key: const Key('input'),
              controller: _textController,
              decoration: const InputDecoration(
                labelText: 'Test Input',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 20),

            // Long press button
            ElevatedButton(
              key: const Key('longpress'),
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.orange,
                padding: const EdgeInsets.all(20),
              ),
              onPressed: () => setState(() => _status = 'Pressed'),
              onLongPress: () => setState(() => _status = 'Long pressed!'),
              child: const Text('Long Press Me'),
            ),
            const SizedBox(height: 20),

            // Swipe area
            Container(
              key: const Key('swipe_area'),
              height: 150,
              color: Colors.purple[50],
              child: const Center(
                child: Text('Swipe Here', style: TextStyle(fontSize: 20)),
              ),
            ),
            const SizedBox(height: 20),

            // List items for drag
            Expanded(
              child: ListView.builder(
                itemCount: 5,
                itemBuilder: (context, i) => Card(
                  key: Key('item_$i'),
                  child: ListTile(
                    title: Text('Item $i'),
                    onTap: () => setState(() => _status = 'Item $i clicked'),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
EOF

# 运行应用
flutter run -d "iPhone 16 Pro" --vm-service-port=50000
```

### 方法 3: 一键脚本（全自动）

```bash
cd /Users/cw/development/flutter-skill

# 运行一键创建和启动脚本
bash demo/auto_setup_demo.sh
```

## 🎬 测试可视化指示器

应用启动后，在 Claude/Cursor 中运行：

```javascript
// 1. 启用可视化（详细模式）
flutter-skill.enable_test_indicators({ enabled: true, style: "detailed" })

// 2. 连接应用
flutter-skill.scan_and_connect()

// 3. 测试点击（蓝色圆圈）
flutter-skill.tap({ key: "btn1" })
// 观察：蓝色圆圈扩散动画 + "Tapping 'Button 1'" 提示

// 4. 测试输入（绿色边框）
flutter-skill.enter_text({ key: "input", text: "Hello Visual Indicators!" })
// 观察：绿色边框闪烁 + "Entering text: '...'" 提示

// 5. 测试长按（橙色圆环）
flutter-skill.long_press({ key: "longpress", duration: 1000 })
// 观察：橙色圆环扩展 1 秒

// 6. 测试滑动（紫色箭头）
flutter-skill.swipe({ direction: "up", distance: 100 })
// 观察：从下到上的紫色箭头轨迹

flutter-skill.swipe({ direction: "down", distance: 100 })
flutter-skill.swipe({ direction: "left", distance: 100 })
flutter-skill.swipe({ direction: "right", distance: 100 })

// 7. 测试拖动（紫色轨迹）
flutter-skill.drag({ from_key: "item_0", to_key: "item_4" })
// 观察：紫色曲线从 item 0 到 item 4

// 8. 截图
flutter-skill.screenshot()
```

## 📹 开始录制

### macOS
```bash
# 方法 1: 截图工具
Cmd+Shift+5 → 录制所选部分 → 选择模拟器窗口 → 录制

# 方法 2: QuickTime
QuickTime → 文件 → 新建屏幕录制
```

### Windows
```bash
Win+G → 开始录制
```

## ✅ 验证可视化效果

运行每个命令后，你应该看到：

| 操作 | 可视化效果 | 颜色 | 提示文字 |
|------|-----------|------|---------|
| tap | 扩散圆圈 | 🔵 蓝色 | "Tapping '...'" |
| enter_text | 边框闪烁 | 🟢 绿色 | "Entering text: '...'" |
| long_press | 圆环扩展 | 🟠 橙色 | "Long pressing" |
| swipe | 箭头轨迹 | 🟣 紫色 | "Swiping up/down/left/right" |
| drag | 移动轨迹 | 🟣 紫色 | "Dragging from ... to ..." |

## 🐛 故障排除

### 指示器不显示？
```javascript
// 检查状态
flutter-skill.get_indicator_status()

// 重新启用
flutter-skill.enable_test_indicators({ enabled: true, style: "detailed" })
```

### 应用启动失败？
```bash
# 确保使用 VM Service 端口
flutter run -d "iPhone 16 Pro" --vm-service-port=50000

# 检查 FlutterSkillBinding 已初始化
# main.dart 中应该有：
FlutterSkillBinding.ensureInitialized();
```

### 找不到元素？
```javascript
// 检查可用元素
flutter-skill.inspect()

// 查看所有 widget
flutter-skill.get_widget_tree()
```

## 🎥 录制清单

- [ ] ✅ 应用已启动
- [ ] ✅ 可视化指示器已启用
- [ ] ✅ 屏幕录制已开始
- [ ] ✅ 逐个运行测试命令
- [ ] ✅ 观察并等待每个动画完成
- [ ] ✅ 停止录制
- [ ] ✅ 保存视频

---

**准备好了吗？选择一个方法开始测试！** 🚀
