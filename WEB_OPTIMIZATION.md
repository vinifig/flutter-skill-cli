# Flutter Skill Web 平台优化说明

## 已完成的优化

### 1. ✅ 截图结果优化

**问题**：默认截图返回全质量图片，导致 base64 编码超过 token 限制（247,878 字符）

**解决方案**：
- 默认 quality: 0.5（降低 50% 文件大小）
- 默认 max_width: 800（适配大部分测试场景）

**使用示例**：
```json
// 默认（优化后）
screenshot()  // 返回 800px 宽，0.5 质量

// 高质量截图（需要时）
screenshot(quality: 1.0, max_width: null)  // 返回原始尺寸和质量

// 更小的预览图
screenshot(quality: 0.3, max_width: 400)  // 更快，更小
```

---

### 2. ✅ tap 工具功能增强

**问题**：
- inspect 返回的 `elem_xxx` ID 无法用于 tap
- 无法点击无文本的图标按钮

**解决方案**：tap 工具现在支持三种方式

#### 方法 1：通过 Widget key
```json
tap(key: "submit_button")
```

#### 方法 2：通过可见文本
```json
tap(text: "提交")
```

#### 方法 3：通过坐标（新增）⭐
```json
// 1. 先调用 inspect 获取元素坐标
inspect()
// 返回：{"id": "elem_012", "center": {"x": 30, "y": 22}}

// 2. 使用坐标点击
tap(x: 30, y: 22)
```

**完整示例**：点击左上角菜单图标
```python
# 1. 查看可交互元素
elements = inspect()

# 2. 找到目标元素
# {
#   "id": "elem_012",
#   "type": "Button",
#   "widgetType": "IconButton",
#   "icon": "IconData(U+0E3DC)",
#   "center": {"x": 30, "y": 22}  # 使用这个坐标
# }

# 3. 点击坐标
tap(x: 30, y: 22)
```

---

## Web 平台特殊限制

### 已知问题

1. **Drawer 菜单不可见**
   - Web 版的 Drawer 实现可能与移动端不同
   - 建议使用 `edge_swipe` 或坐标手势打开

2. **手势操作受限**
   - 某些复杂手势在 Web 上表现不同
   - 优先使用坐标式的手势操作

3. **部分 Widget 可能不渲染**
   - Web 平台的 Widget 树可能简化
   - 使用 `get_widget_tree()` 检查实际渲染的结构

### 建议

- ✅ **优先在 iOS/Android 模拟器上进行完整测试**
- ✅ **Web 平台适合快速原型验证，不适合完整 E2E 测试**

---

## 功能对照表

| 功能 | 状态 | MCP 工具名 | 说明 |
|------|------|-----------|------|
| 坐标点击 | ✅ | `tap(x, y)` | 新增，支持坐标参数 |
| 按元素 ID 点击 | ✅ | `tap(x, y)` | 通过 center 坐标实现 |
| 滑动手势 | ✅ | `swipe(direction, distance)` | 已有 |
| 坐标滑动 | ✅ | `swipe_coordinates(start_x, start_y, end_x, end_y)` | 已有 |
| 边缘滑动 | ✅ | `edge_swipe(edge, direction)` | 已有，可用于 Drawer |
| 滚动到元素 | ✅ | `scroll_to(key, text)` | 已有 |
| 智能滚动 | ✅ | `scroll_until_visible(key, text)` | 已有 |
| 输入文本 | ✅ | `enter_text(key, text)` | 已有 |
| 长按 | ✅ | `long_press(key, text, duration)` | 已有 |
| 坐标长按 | ✅ | `long_press_at(x, y, duration)` | 已有 |
| 双击 | ✅ | `double_tap(key, text)` | 已有 |
| 获取文本 | ✅ | `get_text_value(key)` | 已有 |
| 预设手势 | ✅ | `gesture(preset)` | 已有 drawer_open/drawer_close 等 |

---

## 实用测试流程

### 测试流程 1：测试带图标的底部导航栏

```python
# 1. 连接应用
connect_app(uri: "ws://...")

# 2. 查看所有可交互元素
elements = inspect()

# 3. 找到底部导航栏的图标（通常没有 text）
# 从返回结果中找到类似这样的元素：
# {
#   "id": "elem_015",
#   "type": "Button",
#   "widgetType": "BottomNavigationBarItem",
#   "icon": "IconData(U+0E88E)",
#   "center": {"x": 200, "y": 750}
# }

# 4. 点击图标
tap(x: 200, y: 750)

# 5. 截图验证（优化后的默认设置）
screenshot()
```

### 测试流程 2：打开侧边抽屉菜单

```python
# 方法 1：使用预设手势
gesture(preset: "drawer_open")

# 方法 2：使用边缘滑动
edge_swipe(edge: "left", direction: "right", distance: 250)

# 方法 3：使用坐标滑动
swipe_coordinates(start_x: 0, start_y: 300, end_x: 250, end_y: 300)

# 验证
screenshot(quality: 0.5, max_width: 600)  // 小图快速预览
```

### 测试流程 3：复杂表单填写

```python
# 使用批量操作减少延迟
execute_batch(
  actions: [
    {"action": "tap", "text": "登录"},
    {"action": "wait", "duration": 500},
    {"action": "enter_text", "key": "email_field", "text": "test@example.com"},
    {"action": "enter_text", "key": "password_field", "text": "password123"},
    {"action": "tap", "text": "提交"},
    {"action": "screenshot"},
    {"action": "assert_visible", "text": "欢迎回来"}
  ],
  stop_on_failure: true
)
```

---

## 性能优化建议

### 1. 减少截图频率
```python
# ❌ 不好：每次操作都截图
tap(text: "按钮1")
screenshot()  # 太频繁
tap(text: "按钮2")
screenshot()  # 太频繁

# ✅ 好：关键节点截图
tap(text: "按钮1")
tap(text: "按钮2")
screenshot()  # 只在需要验证时截图
```

### 2. 使用批量操作
```python
# ❌ 不好：多次 RPC 调用
tap(text: "首页")
wait_for_element(text: "内容加载")
tap(text: "下一步")

# ✅ 好：单次批量执行
execute_batch(actions: [...])  # 减少网络延迟
```

### 3. 智能等待
```python
# ❌ 不好：固定延迟
tap(text: "刷新")
wait(duration: 3000)  # 可能太长或太短

# ✅ 好：等待条件
tap(text: "刷新")
wait_for_element(text: "加载完成", timeout: 5000)  # 条件满足立即继续
```

---

## 故障排查

### 问题 1：截图仍然太大

**解决方案**：
```python
# 使用更激进的压缩
screenshot(quality: 0.3, max_width: 400)

# 或使用区域截图
screenshot_region(x: 0, y: 0, width: 400, height: 600)
```

### 问题 2：找不到元素

**排查步骤**：
```python
# 1. 检查元素是否存在
elements = inspect()
print(elements)

# 2. 检查是否需要滚动
scroll_until_visible(text: "目标文本", max_scrolls: 10)

# 3. 使用截图确认当前状态
screenshot()

# 4. 检查 Widget 树
tree = get_widget_tree(max_depth: 5)
```

### 问题 3：手势在 Web 上不工作

**解决方案**：
```python
# 优先使用坐标式操作
swipe_coordinates(start_x: 200, start_y: 400, end_x: 200, end_y: 100)

# 而不是基于元素的手势
swipe(direction: "up", key: "scrollable")  # 在 Web 上可能不可靠
```

---

## 最佳实践

1. **总是先 inspect()**
   - 了解当前屏幕有哪些元素
   - 获取坐标用于后续操作

2. **优先使用坐标**
   - Web 平台上坐标更可靠
   - 特别是对于无文本的图标/图片

3. **使用批量操作**
   - 减少网络往返
   - 提高测试速度

4. **智能等待**
   - 使用 `wait_for_element` 而非固定延迟
   - 使用 `wait_for_idle` 等待动画完成

5. **诊断工具**
   - 使用 `diagnose()` 自动分析问题
   - 使用 `get_logs()` 查看应用日志

---

## 更新日志

- **v0.3.0** (2026-01-31)
  - ✅ 截图默认优化：quality=0.5, max_width=800
  - ✅ tap 支持坐标参数：`tap(x, y)`
  - ✅ 更新工具描述，添加使用示例
  - ✅ 创建 Web 平台优化文档
