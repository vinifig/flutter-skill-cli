# Flutter Skill Web 平台快速参考

## 🚀 常用操作速查表

### 点击元素

```python
# 方法 1: 通过文本（简单）
tap(text: "提交")

# 方法 2: 通过 Widget key（精确）
tap(key: "submit_button")

# 方法 3: 通过坐标（万能）⭐
inspect()  # 先查看元素
tap(x: 30, y: 22)  # 使用返回的 center 坐标
```

### 截图

```python
# 默认（优化后）- 推荐
screenshot()  # quality=0.5, max_width=800

# 高质量（按需）
screenshot(quality: 1.0, max_width: null)

# 超小预览
screenshot(quality: 0.3, max_width: 400)
```

### 手势操作

```python
# 打开侧边栏（推荐）
gesture(preset: "drawer_open")

# 或使用边缘滑动
edge_swipe(edge: "left", direction: "right")

# 下拉刷新
gesture(preset: "pull_refresh")

# 自定义滑动
swipe_coordinates(start_x: 100, start_y: 200, end_x: 100, end_y: 500)
```

### 查看元素

```python
# 查看所有可交互元素
elements = inspect()

# 查看完整 Widget 树
tree = get_widget_tree(max_depth: 5)

# 查看所有文本
texts = get_text_content()
```

---

## 💡 常见场景

### 场景 1: 点击图标按钮

```python
# 1. 查看元素
elements = inspect()

# 2. 找到图标（通常是 IconButton，没有 text）
# 返回: {"id": "elem_012", "widgetType": "IconButton", "center": {"x": 30, "y": 22}}

# 3. 点击坐标
tap(x: 30, y: 22)
```

### 场景 2: 填写表单

```python
# 方式 1: 逐步操作
enter_text(key: "email_field", text: "test@example.com")
enter_text(key: "password_field", text: "password123")
tap(text: "登录")

# 方式 2: 批量操作（更快）
execute_batch(actions: [
  {"action": "enter_text", "key": "email_field", "text": "test@example.com"},
  {"action": "enter_text", "key": "password_field", "text": "password123"},
  {"action": "tap", "text": "登录"}
])
```

### 场景 3: 滚动查找元素

```python
# 自动滚动直到找到元素
scroll_until_visible(text: "目标内容", direction: "down", max_scrolls: 10)

# 或手动滚动
swipe(direction: "up", distance: 300)
```

### 场景 4: 等待加载

```python
# ❌ 不要用固定延迟
wait(duration: 3000)

# ✅ 用条件等待
wait_for_element(text: "加载完成", timeout: 5000)

# 或等待动画结束
wait_for_idle(timeout: 5000)
```

---

## ⚠️ Web 平台注意事项

### DO ✅

- **优先使用坐标**：`tap(x, y)` 比 `tap(text)` 更可靠
- **使用预设手势**：`gesture(preset: "drawer_open")`
- **批量操作**：`execute_batch()` 减少延迟
- **条件等待**：`wait_for_element()` 而非固定延迟
- **默认截图**：`screenshot()` 自动优化

### DON'T ❌

- **不要频繁截图**：每次操作都截图会很慢
- **不要用固定延迟**：网络延迟不确定
- **不要盲目点击**：先 `inspect()` 再操作
- **不要忽略坐标**：图标/图片必须用坐标

---

## 🔍 故障排查

### 截图太大？

```python
# 方案 1: 更小的尺寸
screenshot(quality: 0.3, max_width: 400)

# 方案 2: 区域截图
screenshot_region(x: 0, y: 0, width: 400, height: 600)
```

### 找不到元素？

```python
# 1. 检查元素列表
elements = inspect()

# 2. 检查是否需要滚动
scroll_until_visible(text: "目标")

# 3. 查看 Widget 树
tree = get_widget_tree()

# 4. 截图确认
screenshot()
```

### 点击不生效？

```python
# 1. 确认元素可见
assert_visible(text: "按钮")

# 2. 尝试坐标点击
elements = inspect()
tap(x: element.center.x, y: element.center.y)

# 3. 等待元素稳定
wait_for_idle()
tap(text: "按钮")
```

### 手势不工作？

```python
# ❌ 不推荐：基于元素的手势
swipe(direction: "up", key: "list")

# ✅ 推荐：基于坐标的手势
swipe_coordinates(start_x: 200, start_y: 500, end_x: 200, end_y: 100)

# ✅ 推荐：使用预设
gesture(preset: "drawer_open")
```

---

## 📋 完整工具列表

### 连接管理
- `launch_app(project_path)` - 启动应用
- `scan_and_connect()` - 自动连接
- `connect_app(uri)` - 指定 URI 连接
- `disconnect()` - 断开连接
- `stop_app()` - 停止应用

### 元素查看
- `inspect()` - 可交互元素列表 ⭐
- `get_widget_tree(max_depth)` - Widget 树
- `get_text_content()` - 所有文本
- `find_by_type(type)` - 按类型查找

### 基础操作
- `tap(key/text/x,y)` - 点击 ⭐
- `double_tap(key/text)` - 双击
- `long_press(key/text)` - 长按
- `enter_text(key, text)` - 输入文本

### 手势操作
- `swipe(direction, distance)` - 滑动
- `swipe_coordinates(...)` - 坐标滑动 ⭐
- `edge_swipe(edge, direction)` - 边缘滑动
- `gesture(preset)` - 预设手势 ⭐
- `drag(from_key, to_key)` - 拖拽

### 滚动操作
- `scroll_to(key/text)` - 滚动到元素
- `scroll_until_visible(key/text)` - 智能滚动 ⭐

### 等待验证
- `wait_for_element(key/text)` - 等待出现
- `wait_for_gone(key/text)` - 等待消失
- `wait_for_idle()` - 等待空闲 ⭐
- `assert_visible(key/text)` - 断言可见
- `assert_not_visible(key/text)` - 断言不可见
- `assert_text(key, expected)` - 断言文本

### 截图工具
- `screenshot()` - 全屏截图 ⭐
- `screenshot_region(x, y, w, h)` - 区域截图
- `screenshot_element(key)` - 元素截图

### 状态查询
- `get_text_value(key)` - 获取文本
- `get_checkbox_state(key)` - 获取复选框状态
- `get_slider_value(key)` - 获取滑块值
- `get_page_state()` - 页面状态
- `get_current_route()` - 当前路由

### 批量操作
- `execute_batch(actions)` - 批量执行 ⭐

### 调试工具
- `get_logs()` - 应用日志
- `get_errors()` - 错误列表
- `diagnose()` - 智能诊断 ⭐
- `get_frame_stats()` - 帧率统计
- `get_memory_stats()` - 内存统计

### 导航操作
- `go_back()` - 返回
- `get_navigation_stack()` - 导航栈

### 开发工具
- `hot_reload()` - 热重载
- `hot_restart()` - 热重启

---

## 🎯 最佳实践速记

1. **先 inspect()** - 了解当前屏幕
2. **用坐标** - Web 平台更可靠
3. **批量操作** - 减少网络延迟
4. **智能等待** - 不用固定延迟
5. **优化截图** - 使用默认设置

---

## 📚 详细文档

- **完整指南**: `WEB_OPTIMIZATION.md`
- **发布说明**: `RELEASE_NOTES_v0.3.1.md`
- **项目文档**: `CLAUDE.md`

---

**版本**: v0.3.1
**更新**: 2026-01-31
