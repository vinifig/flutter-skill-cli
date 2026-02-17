<p align="center">
  <a href="https://github.com/ai-dashboad/flutter-skill">
    <img src="assets/demo-teaser.gif" alt="AI testing a TikTok clone across 8 platforms" width="640">
  </a>
</p>

<h1 align="center">flutter-skill</h1>

<p align="center">
  <strong>Give any AI agent eyes and hands inside any running app.</strong><br>
  8 platforms. Zero test code. One MCP server.
</p>

<p align="center">
  <a href="https://github.com/ai-dashboad/flutter-skill/stargazers"><img src="https://img.shields.io/github/stars/ai-dashboad/flutter-skill?style=flat&color=yellow" alt="Stars"></a>
  <a href="https://pub.dev/packages/flutter_skill"><img src="https://img.shields.io/pub/v/flutter_skill.svg" alt="pub.dev"></a>
  <a href="https://www.npmjs.com/package/flutter-skill"><img src="https://img.shields.io/npm/v/flutter-skill.svg" alt="npm"></a>
  <a href="https://github.com/ai-dashboad/flutter-skill/actions"><img src="https://img.shields.io/github/actions/workflow/status/ai-dashboad/flutter-skill/ci.yml?label=tests" alt="CI"></a>
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-MIT-blue.svg" alt="License"></a>
</p>

<p align="center">
  <a href="#30-second-demo">Demo</a> •
  <a href="#quick-start">Quick Start</a> •
  <a href="#8-platforms-one-tool">Platforms</a> •
  <a href="#why-not-playwright--appium--detox">vs Others</a> •
  <a href="docs/USAGE_GUIDE.md">Docs</a>
</p>

<p align="center"><b>🚀 Zero config. Zero test code. Just talk to your AI.</b></p>

<p align="center"><sub>If this saves you time, please consider <a href="https://github.com/ai-dashboad/flutter-skill/stargazers">starring the repo ⭐</a> — it helps others find it!</sub></p>

---

## 30-Second Demo

https://github.com/user-attachments/assets/d4617c73-043f-424c-9a9a-1a61d4c2d3c6

> **One prompt. 28 AI-driven actions. Zero test code.** The AI explores a TikTok clone, navigates tabs, scrolls feeds, tests search, fills forms — all autonomously.

---

## Why This Exists

Writing E2E tests is painful. Maintaining them is worse. **flutter-skill** takes a different approach:

- 🔌 **Connects any AI agent** (Claude, Cursor, Windsurf, Copilot, OpenClaw) directly to your running app via [MCP](https://modelcontextprotocol.io/)
- 👀 **The agent sees your screen** — taps buttons, types text, scrolls, navigates — like a human tester who never sleeps
- ✅ **Zero test code** — no Page Objects, no XPath, no brittle selectors. Just plain English
- ⚡ **Zero config** — 2 lines of code, works on all 8 platforms

```
You: "Test the checkout flow with an empty cart, then add 3 items and complete purchase"

Your AI agent handles the rest — screenshots, taps, text entry, assertions, navigation.
No Page Objects. No XPath. No brittle selectors. Just plain English.
```

---

## Quick Start

**1. Install** (30 seconds)

```bash
npm install -g flutter-skill
```

**2. Add to your AI** (copy-paste into MCP config)

```json
{
  "mcpServers": {
    "flutter-skill": {
      "command": "flutter-skill",
      "args": ["server"]
    }
  }
}
```

> Works with **Claude Desktop, Cursor, Windsurf, Copilot, Cline, OpenClaw** — any MCP-compatible agent.

**3. Add to your app** (2 lines for Flutter)

```dart
import 'package:flutter_skill/flutter_skill.dart';

void main() {
  if (kDebugMode) FlutterSkillBinding.ensureInitialized();
  runApp(MyApp());
}
```

**4. Test** — just talk to your AI:

> *"Launch my app, explore every screen, and report any bugs"*

That's it. **Zero configuration. Zero test code. Works in under 60 seconds.**

<details>
<summary>📦 More install methods (Homebrew, Scoop, Docker, IDE, Agent Skill)</summary>

| Method | Command |
|--------|---------|
| npm | `npm install -g flutter-skill` |
| Homebrew | `brew install ai-dashboad/flutter-skill/flutter-skill` |
| Scoop | `scoop install flutter-skill` |
| Docker | `docker pull ghcr.io/ai-dashboad/flutter-skill` |
| pub.dev | `dart pub global activate flutter_skill` |
| VSCode | Extensions → "Flutter Skill" |
| JetBrains | Plugins → "Flutter Skill" |
| Agent Skill | `npx skills add ai-dashboad/flutter-skill` |
| Zero-config | `flutter-skill init` (auto-detects & patches your app) |

</details>

---

## 8 Platforms, One Tool

Most testing tools work on 1-2 platforms. flutter-skill works on **8**.

| Platform | SDK | Test Score |
|----------|-----|:----------:|
| **Flutter** (iOS/Android/Web) | [`flutter_skill`](https://pub.dev/packages/flutter_skill) | ✅ 188/195 |
| **React Native** | [`sdks/react-native`](sdks/react-native/) | ✅ 75/75 |
| **Electron** | [`sdks/electron`](sdks/electron/) | ✅ 75/75 |
| **Tauri** (Rust) | [`sdks/tauri`](sdks/tauri/) | ✅ 75/75 |
| **Android** (Kotlin) | [`sdks/android`](sdks/android/) | ✅ 74/75 |
| **KMP Desktop** | [`sdks/kmp`](sdks/kmp/) | ✅ 75/75 |
| **.NET MAUI** | [`sdks/dotnet-maui`](sdks/dotnet-maui/) | ✅ 75/75 |
| **iOS** (Swift/UIKit) | [`sdks/ios`](sdks/ios/) | ✅ 19/19 |

**Total: 656/664 tests passing (98.8%)** — each platform tested against a complex social media app with 50+ elements.

---

## ⚡ Performance

Real benchmarks from automated test runs against a complex social media app:

| Operation | Web (CDP) | Electron | Android |
|-----------|:---------:|:--------:|:-------:|
| `connect` | 93 ms | 55 ms | 103 ms |
| `tap` | **1 ms** | **1 ms** | **2 ms** |
| `enter_text` | **1 ms** | **1 ms** | **2 ms** |
| `inspect` | 3 ms | 12 ms | 10 ms |
| `snapshot` | **2 ms** | **8 ms** | **29 ms** |
| `screenshot` | **31 ms** | **80 ms** | **88 ms** |
| `eval` | **1 ms** | — | — |

**Token efficiency:** `snapshot()` returns a structured element tree instead of an image — **87–99% fewer tokens** than sending screenshots to your AI agent.

**How fast is that?** A `tap` takes 1–2 ms end-to-end. Browser automation tools like Playwright and Selenium typically take 50–100 ms for the same operation. That's 50–100× faster, because flutter-skill talks directly to the app runtime instead of going through WebDriver or CDP indirection.

---

## Why Not Playwright / Appium / Detox?

| | flutter-skill | Playwright | Appium | Detox |
|---|:---:|:---:|:---:|:---:|
| **Setup time** | 30 sec | Minutes | Hours | Hours |
| **Test code needed** | ❌ None | ✅ Yes | ✅ Yes | ✅ Yes |
| **AI-native (MCP)** | ✅ | ❌ | ❌ | ❌ |
| **Platforms** | 8 | 3 (web) | Mobile | React Native |
| **Natural language** | ✅ | ❌ | ❌ | ❌ |
| **Maintenance** | Zero | High | High | Medium |
| **Flutter support** | ✅ Native | Partial | Partial | ❌ |
| **Desktop apps** | ✅ | ✅ | ❌ | ❌ |

**flutter-skill is the only AI-native E2E testing tool that works across mobile, web, and desktop.**

---

## What It Can Do

<table>
<tr>
<td width="50%" valign="top">

### 👀 See
- `screenshot` — capture the screen
- `inspect_interactive` — all tappable/typeable elements with semantic refs
- `find_element` / `wait_for_element`
- `get_elements` — full element tree

</td>
<td width="50%" valign="top">

### 👆 Interact
- `tap` / `long_press` / `swipe` / `drag`
- `enter_text` / `set_text` / `clear_text`
- `scroll` — all directions
- `go_back` / `press_key`

</td>
</tr>
<tr>
<td valign="top">

### 🔍 Inspect (v0.8.0)
- **Semantic refs**: `button:Login`, `input:Email`
- Stable across UI changes
- `tap(ref: "button:Submit")`
- 7 roles: button, input, toggle, slider, select, link, item

</td>
<td valign="top">

### 🚀 Control
- `launch_app` — launch with flavors
- `hot_reload` / `hot_restart`
- `get_logs` / `get_errors`
- `scan_and_connect` — auto-find apps

</td>
</tr>
</table>

<details>
<summary><strong>40+ tools — full reference</strong></summary>

**Launch & Connect:** `launch_app`, `scan_and_connect`, `hot_reload`, `hot_restart`, `list_sessions`, `switch_session`, `close_session`

**Screen:** `screenshot`, `screenshot_region`, `screenshot_element`, `native_screenshot`, `inspect`, `inspect_interactive`, `get_widget_tree`, `find_by_type`, `get_text_content`

**Interaction:** `tap`, `double_tap`, `long_press`, `enter_text`, `set_text`, `clear_text`, `swipe`, `scroll_to`, `drag`, `go_back`, `press_key`, `native_tap`, `native_input_text`, `native_swipe`

**Assertions:** `assert_text`, `assert_visible`, `assert_not_visible`, `assert_element_count`, `wait_for_element`, `wait_for_gone`, `get_checkbox_state`, `get_slider_value`, `get_text_value`

**Debug:** `get_logs`, `get_errors`, `get_performance`, `get_memory_stats`

</details>

---

## Platform Setup

<details>
<summary><strong>Flutter</strong> (iOS / Android / Web)</summary>

```yaml
dependencies:
  flutter_skill: ^0.8.3
```

```dart
import 'package:flutter_skill/flutter_skill.dart';

void main() {
  if (kDebugMode) FlutterSkillBinding.ensureInitialized();
  runApp(MyApp());
}
```

</details>

<details>
<summary><strong>React Native</strong></summary>

```bash
npm install flutter-skill-react-native
```

```js
import FlutterSkill from 'flutter-skill-react-native';
FlutterSkill.start();
```

</details>

<details>
<summary><strong>Electron</strong></summary>

```bash
npm install flutter-skill-electron
```

```js
const { FlutterSkillBridge } = require('flutter-skill-electron');
FlutterSkillBridge.start(mainWindow);
```

</details>

<details>
<summary><strong>iOS (Swift)</strong></summary>

```swift
// Swift Package Manager: FlutterSkillSDK
import FlutterSkill
FlutterSkillBridge.shared.start()

Text("Hello").flutterSkillId("greeting")
```

</details>

<details>
<summary><strong>Android (Kotlin)</strong></summary>

```kotlin
implementation("com.flutterskill:flutter-skill:0.8.0")

FlutterSkillBridge.start(this)
```

</details>

<details>
<summary><strong>Tauri (Rust)</strong></summary>

```toml
[dependencies]
flutter-skill-tauri = "0.8.0"
```

</details>

<details>
<summary><strong>KMP Desktop</strong></summary>

Add Gradle dependency — see [`sdks/kmp`](sdks/kmp/) for details.

</details>

<details>
<summary><strong>.NET MAUI</strong></summary>

Add NuGet package — see [`sdks/dotnet-maui`](sdks/dotnet-maui/) for details.

</details>

---

## Example Prompts

Just tell your AI what to test:

| Prompt | What happens |
|--------|-------------|
| *"Test login with wrong password"* | Screenshots → enters creds → taps login → verifies error |
| *"Explore every screen and report bugs"* | Systematically navigates all screens, tests all elements |
| *"Fill registration with edge cases"* | Tests emoji 🌍, long strings, empty fields, special chars |
| *"Compare checkout flow on iOS and Android"* | Runs same test on both platforms, compares screenshots |
| *"Take screenshots of all 5 tabs"* | Taps each tab, captures state |

---

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md) for guidelines.

```bash
git clone https://github.com/ai-dashboad/flutter-skill
cd flutter-skill
dart pub get
dart run bin/flutter_skill.dart server  # Start MCP server
```

---

## Links

| | |
|---|---|
| 📦 [pub.dev](https://pub.dev/packages/flutter_skill) | 🧩 [VSCode](https://marketplace.visualstudio.com/items?itemName=AIDashboard.flutter-skill) |
| 📦 [npm](https://www.npmjs.com/package/flutter-skill) | 🧩 [JetBrains](https://plugins.jetbrains.com/plugin/29991-flutter-skill) |
| 🍺 [Homebrew](https://github.com/ai-dashboad/homebrew-flutter-skill) | 📖 [Docs](docs/USAGE_GUIDE.md) |
| 🤖 [Agent Skill](https://skills.sh/ai-dashboad/flutter-skill) | 📋 [Changelog](CHANGELOG.md) |

---

<p align="center">
  <strong>⭐ If flutter-skill saves you time, star it so others can find it too!</strong>
</p>

<p align="center">MIT License © 2025</p>
