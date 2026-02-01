# Flutter 3.x Compatibility Guide

## Problem Overview

**Issue**: Flutter Skill cannot connect to apps launched with Flutter 3.x

**Root Cause**: Flutter 3.x uses **DTD (Dart Tooling Daemon)** protocol by default instead of the traditional **VM Service** protocol.

```
Flutter 3.x default output:
✅ DTD URI:        ws://127.0.0.1:57868/token=/ws      (新协议)
❌ VM Service URI: http://127.0.0.1:50753/token=/     (旧协议，可能不输出)

Flutter Skill requires: VM Service URI ✅
```

---

## Error Symptoms

### 1. Connection Error
```json
{
  "error": "getVM method not found"
}
```
**Cause**: Trying to connect to DTD URI with VM Service client

### 2. Timeout Error
```json
{
  "error": {
    "code": "E301",
    "message": "Found DTD URI but no VM Service URI",
    "found_uris": {
      "dtd": "ws://127.0.0.1:57868/xxx=/ws"
    }
  }
}
```
**Cause**: App launched successfully but only DTD URI is available

---

## Solutions

### Solution 1: Force VM Service Protocol (Recommended) ⭐

**Add `--vm-service-port` flag when launching:**

```python
# MCP call
launch_app(
  project_path: "/path/to/project",
  device_id: "iPhone 16 Pro",
  extra_args: ["--vm-service-port=50000"]  # ← Force VM Service
)

# CLI
flutter_skill launch . --extra-args="--vm-service-port=50000"

# Manual
flutter run -d "iPhone 16 Pro" --vm-service-port=50000
```

**What this does**:
- Forces Flutter to enable VM Service protocol
- Outputs both DTD URI and VM Service URI
- Flutter Skill can now connect successfully

---

### Solution 2: Use Dart MCP for DTD Protocol

If you only need **app lifecycle management** (launch, logs, hot reload):

```python
# Use Dart MCP instead of Flutter Skill
mcp__dart__launch_app(device_id: "iPhone 16 Pro")
mcp__dart__connect_dart_tooling_daemon(uri: "ws://...")
mcp__dart__get_app_logs()
mcp__dart__hot_reload()
```

**Limitations**:
- ❌ No UI automation (tap, swipe, screenshot)
- ❌ No element interaction
- ✅ App management and monitoring only

---

### Solution 3: Enable Flutter Driver for UI Testing

For **complete E2E testing** with DTD protocol:

#### Step 1: Create driver entry point

```dart
// lib/driver_main.dart
import 'package:flutter_driver/driver_extension.dart';
import 'main.dart' as app;

void main() {
  enableFlutterDriverExtension();
  app.main();
}
```

#### Step 2: Launch with driver target

```bash
flutter run --target=lib/driver_main.dart -d "iPhone 16 Pro"
```

#### Step 3: Use Flutter Driver via Dart MCP

```python
mcp__dart__flutter_driver_tap(element: "login_button")
mcp__dart__flutter_driver_scroll(...)
```

---

### Solution 4: Use Integration Tests

For **automated testing without MCP**:

```dart
// test/integration_test/app_test.dart
import 'package:integration_test/integration_test.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('E2E test', (tester) async {
    await tester.pumpWidget(MyApp());
    await tester.tap(find.byKey(Key('button')));
    expect(find.text('Success'), findsOneWidget);
  });
}
```

Run:
```bash
flutter test integration_test/app_test.dart
```

---

## Feature Comparison

| Feature | Flutter Skill (VM Service) | Dart MCP (DTD) | Flutter Driver | Integration Test |
|---------|---------------------------|----------------|----------------|------------------|
| Launch app | ✅ | ✅ | ✅ | ✅ |
| Hot reload | ✅ | ✅ | ❌ | ❌ |
| UI inspection | ✅ | ⚠️ (limited) | ✅ | ✅ |
| Tap/click | ✅ | ❌ | ✅ | ✅ |
| Swipe/scroll | ✅ | ❌ | ✅ | ✅ |
| Screenshot | ✅ | ❌ | ✅ | ⚠️ |
| Text input | ✅ | ❌ | ✅ | ✅ |
| Logs monitoring | ✅ | ✅ | ❌ | ⚠️ |
| MCP integration | ✅ | ✅ | ⚠️ | ❌ |
| **Setup difficulty** | Easy | Easy | Medium | Easy |
| **Best for** | UI automation | App monitoring | Advanced E2E | CI/CD testing |

---

## Recommended Workflows

### For UI Automation (E2E Testing)

```bash
# 1. Launch with VM Service
flutter_skill launch . --extra-args="--vm-service-port=50000"

# 2. Use Flutter Skill MCP tools
inspect()
tap(text: "Login")
enter_text(key: "email", text: "test@example.com")
screenshot()
```

### For App Monitoring

```bash
# 1. Launch normally (DTD is fine)
mcp__dart__launch_app(device_id: "...")

# 2. Use Dart MCP tools
mcp__dart__get_app_logs()
mcp__dart__get_runtime_errors()
mcp__dart__hot_reload()
```

### For Mixed Usage

```bash
# Terminal 1: Launch with VM Service
flutter run --vm-service-port=50000

# Terminal 2: Use Flutter Skill for UI
flutter_skill connect <vm-service-uri>
flutter_skill tap "button"

# Terminal 3: Use Dart MCP for monitoring
# (automatically finds DTD URI)
mcp__dart__get_app_logs()
```

---

## Troubleshooting

### Q: How do I know which protocol my app is using?

**Check the flutter run output:**

```
✅ DTD protocol:
ws://127.0.0.1:57868/xxx=/ws

✅ VM Service protocol:
http://127.0.0.1:50753/xxx=/
The Dart VM service is listening on...
```

### Q: Can I use both protocols at the same time?

**Yes!** Use `--vm-service-port` and both will be available:
```bash
flutter run --vm-service-port=50000

# Output will show both:
# DTD:        ws://127.0.0.1:57868/...
# VM Service: http://127.0.0.1:50000/...
```

### Q: Why does Dart MCP work but Flutter Skill doesn't?

**Different protocols:**
- **Dart MCP**: Uses DTD protocol (Flutter 3.x default)
- **Flutter Skill**: Uses VM Service protocol (older, more powerful)

**Think of it like:**
- DTD = Modern REST API (limited but standard)
- VM Service = Full database access (powerful but requires setup)

### Q: When should I use each tool?

| Use Case | Recommended Tool |
|----------|-----------------|
| Full E2E testing (tap, swipe, screenshot) | **Flutter Skill** + `--vm-service-port` |
| App monitoring (logs, errors, hot reload) | **Dart MCP** |
| CI/CD automated tests | **Integration Test** |
| Manual debugging | **Flutter DevTools** |

---

## Version Compatibility

| Flutter Version | Default Protocol | Flutter Skill Support | Solution |
|-----------------|-----------------|----------------------|----------|
| 2.x | VM Service | ✅ Works out of box | None needed |
| 3.0 - 3.10 | VM Service | ✅ Works out of box | None needed |
| 3.11+ | DTD | ⚠️ Requires flag | Use `--vm-service-port` |
| 3.41+ (beta) | DTD only | ⚠️ Requires flag | Use `--vm-service-port` |

---

## Future Improvements

Flutter Skill roadmap:
- [ ] Auto-detect DTD URI and suggest using `--vm-service-port`
- [ ] Support DTD protocol natively
- [ ] Hybrid mode: Use DTD for monitoring, VM Service for UI
- [ ] Better error messages for protocol mismatch

---

## References

- [Flutter VM Service Documentation](https://github.com/dart-lang/sdk/blob/main/runtime/vm/service/service.md)
- [DTD Protocol Specification](https://github.com/flutter/flutter/wiki/The-Dart-Tooling-Daemon-DTD)
- [Flutter DevTools](https://docs.flutter.dev/tools/devtools)
- [Integration Testing](https://docs.flutter.dev/testing/integration-tests)

---

**Last Updated**: 2026-01-31
**Flutter Skill Version**: v0.3.1+
**Tested Flutter Versions**: 3.41.0-0.1.pre
