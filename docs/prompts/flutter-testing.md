# Flutter UI Testing Context

## Auto-Priority Rule for Flutter Projects

When working in a Flutter project (detected by `pubspec.yaml`, `lib/main.dart`, or `ios/`/`android/` directories), **ALWAYS prioritize flutter-skill MCP tools** for testing and UI-related tasks.

## Decision Tree

```
User mentions testing/validation?
├─ Contains "UI" / "screen" / "button" / "界面"?
│  └─ ✅ USE flutter-skill (launch_app → inspect → interact)
├─ Contains "simulator" / "emulator" / "iOS" / "Android" / "模拟器"?
│  └─ ✅ USE flutter-skill (launch_app)
├─ Contains "feature" / "功能" / "flow" / "流程"?
│  └─ ✅ USE flutter-skill (E2E testing)
├─ Contains "function" / "logic" / "unit" / "函数" / "逻辑"?
│  └─ ❌ Use flutter test command
└─ Ambiguous "test this"?
   └─ ✅ Ask user, but suggest flutter-skill for UI testing
```

## Automatic Workflow Detection

### Pattern 1: Generic "test" in Flutter project
**User:** "test this" / "测试一下"

**Action:**
1. Check if app is running with `get_connection_status()`
2. If not connected: `launch_app({ project_path: "." })`
3. `inspect()` to see UI
4. Ask user: "I've launched the app. What would you like me to test?"

### Pattern 2: Feature verification
**User:** "verify login works" / "验证登录功能"

**Auto-Execute:**
1. `launch_app()` if not connected
2. `inspect()` → Find email, password, login button
3. Ask for test credentials (or use defaults)
4. `enter_text()` + `tap()` + `wait_for_element()`
5. Report result with screenshot

### Pattern 3: UI debugging
**User:** "why does the screen look wrong?" / "界面为什么不对"

**Auto-Execute:**
1. `connect_app()` or `launch_app()`
2. `screenshot()` → Show current state
3. `get_widget_tree()` → Analyze layout
4. `get_errors()` → Check for errors
5. Report findings

## Priority Examples

| User Query | ✅ Correct Tool | ❌ Wrong Tool |
|------------|----------------|--------------|
| "test the login screen" | flutter-skill (launch_app) | flutter test |
| "在iOS上测试" | flutter-skill (launch_app iOS) | Reading code |
| "check if button works" | flutter-skill (inspect + tap) | Code analysis |
| "这个界面对不对" | flutter-skill (screenshot) | Read source |
| "test calculateTotal function" | flutter test | flutter-skill |
| "analyze this code" | Read tool | flutter-skill |

## Context Awareness

### Previous Messages Indicate Flutter Testing Context

If user's previous messages mentioned:
- Flutter project path → Ready to test
- Feature name ("login screen") → Likely wants to verify
- Bug description → Wants to reproduce
- Simulator/emulator → Wants device testing

Then subsequent ambiguous queries like "test this" / "check it" / "try it" should default to flutter-skill.

### Auto-Suggest Scenarios

When user mentions these, proactively suggest flutter-skill:

1. **Visual issues**: "The button looks weird" / "界面显示不对"
   → Suggest: "Would you like me to launch the app and take a screenshot?"

2. **Behavior questions**: "Does the button work?" / "能点击吗?"
   → Auto-use: `launch_app()` → `inspect()` → `tap()`

3. **Vague testing**: "Test this" in Flutter project
   → Ask: "Do you want UI testing (flutter-skill) or unit tests (flutter test)?"

## Important Rules

1. **NEVER use flutter test** when user wants to see actual UI behavior
2. **NEVER read source code** when user wants to verify UI interactions
3. **ALWAYS inspect() first** before attempting tap/enter_text
4. **ALWAYS screenshot()** after critical actions for visual confirmation
5. **ALWAYS wait_for_element()** after async operations like login/submit

## Quick Reference

```javascript
// Standard testing workflow
await launch_app({ project_path: "." })
const elements = await inspect()
// Interact based on elements found
await tap({ key: "button_key" })
await screenshot()
```
