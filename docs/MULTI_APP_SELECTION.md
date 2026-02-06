# Multi-App Selection

## Problem: Multiple Apps in Same Location

**Scenario:** You're developing a cross-platform Flutter app and testing on multiple devices simultaneously:

```bash
cd /Users/you/my_flutter_app

# Terminal 1
flutter run -d "iPhone 16 Pro"

# Terminal 2
flutter run -d "Android Emulator"

# Terminal 3
flutter_skill inspect  # Which app should it connect to?
```

Both apps run from the same project directory, so directory-based matching finds 2 candidates.

## Solution: Device-Aware Selection

### 1. **Automatic Device Detection**

The discovery mechanism now extracts device information from:
- Parent `flutter run` process command-line arguments (`-d` or `--device` flag)
- Process relationships (parent PID mapping)
- Heuristic detection from process info

Example device IDs detected:
- `"iPhone 16 Pro"` - iOS Simulator
- `"Android Emulator"` - Android Emulator
- `"00008030-001254C83AE4802E"` - Physical iPhone
- `"BCCC538A-B4BB-45F4-8F80-9F9C44B9ED8B"` - Device UUID

### 2. **Enhanced Selection UI**

When multiple apps are in the same location, the selection UI adapts:

```
🔍 Found 2 Flutter apps running in the same location:

   /Users/you/my_flutter_app

1. 📱 iPhone 16 Pro - Port 50000
2. 📱 Android Emulator - Port 50001

Select app to connect (1-2): _
```

Notice:
- Shows the common project path once (not repeated)
- Highlights device differences with 📱 emoji
- Keeps the selection focused on what matters (device + port)

### 3. **Device Filtering (Future)**

Smart selection supports device filtering programmatically:

```dart
// Auto-select iOS app
final app = await ProcessBasedDiscovery.smartSelect(
  apps,
  deviceId: 'iPhone',  // Partial match: "iPhone 16 Pro"
);

// Auto-select Android app
final app = await ProcessBasedDiscovery.smartSelect(
  apps,
  deviceId: 'Android',  // Partial match: "Android Emulator"
);
```

**Future CLI enhancement:**
```bash
# Will auto-select iOS device
flutter_skill inspect --device iPhone

# Will auto-select Android device
flutter_skill inspect --device Android
```

## Selection Priority

When multiple apps exist, selection happens in this order:

### 1. **Exact Directory Match**
```bash
cd /Users/you/project-a
flutter_skill inspect  # Only considers apps in project-a
```

### 2. **Device Filter (if provided)**
```bash
flutter_skill inspect --device iPhone  # Only considers iPhone apps
```

### 3. **Unique Match**
- If only 1 app matches directory + device filters → auto-select it
- If multiple apps match → show selection UI

### 4. **User Selection**
- Display apps with device info
- User types 1-N to select

## Implementation Details

### FlutterApp Class

```dart
class FlutterApp {
  final String vmServiceUri;   // ws://127.0.0.1:50000/token=/ws
  final int port;               // 50000
  final int pid;                // 47555
  String? dtdUri;               // Optional DTD URI
  String? projectPath;          // /Users/you/my_flutter_app
  String? deviceId;             // "iPhone 16 Pro" (NEW!)
}
```

### Device Detection Logic

```dart
static Future<void> _enrichWithDeviceInfo(
  List<FlutterApp> apps,
  List<String> psLines,
) async {
  // 1. Extract device from flutter run commands
  final pidToDevice = <int, String>{};
  for (final line in psLines) {
    if (line.contains('flutter') && line.contains('run')) {
      // Extract -d "device" or --device=device
      final deviceMatch = RegExp(r'-d\s+"([^"]+)"').firstMatch(line);
      // ... store in pidToDevice map
    }
  }

  // 2. Map development-service to parent flutter run
  for (final app in apps) {
    final ppid = getParentPid(app.pid);
    if (pidToDevice.containsKey(ppid)) {
      app.deviceId = pidToDevice[ppid];
    }
  }
}
```

### Smart Selection Logic

```dart
static Future<FlutterApp?> smartSelect(
  List<FlutterApp> apps, {
  String? cwd,
  String? deviceId,  // NEW!
}) async {
  // 1. Filter by directory
  final matches = apps.where((app) =>
    app.projectPath == cwd
  ).toList();

  // 2. Filter by device (if provided)
  if (deviceId != null) {
    final deviceMatches = matches.where((app) =>
      app.deviceId?.contains(deviceId)
    ).toList();

    if (deviceMatches.length == 1) {
      return deviceMatches.first;  // Auto-select!
    }
  }

  // 3. Unique match or user selection
  if (matches.length == 1) return matches.first;
  return await userSelect(matches);
}
```

## Example Scenarios

### Scenario 1: Two apps, same location, different devices

**Setup:**
```bash
cd /Users/you/my_app
flutter run -d "iPhone 16 Pro"      # PID 1001 → Port 50000
flutter run -d "Android Emulator"   # PID 1002 → Port 50001
```

**Behavior:**
```bash
cd /Users/you/my_app
flutter_skill inspect

# Output:
# 🔍 Found 2 Flutter apps running in the same location:
#    /Users/you/my_app
#
# 1. 📱 iPhone 16 Pro - Port 50000
# 2. 📱 Android Emulator - Port 50001
#
# Select app to connect (1-2): _
```

### Scenario 2: Future with device filter

```bash
cd /Users/you/my_app
flutter_skill inspect --device iPhone

# Output:
# 🔍 Auto-discovering running Flutter apps...
# ✅ Connected: ws://127.0.0.1:50000/.../ws (iPhone 16 Pro)
```

### Scenario 3: Three apps, different locations

**Setup:**
```bash
# App 1: /Users/you/project-a → iPhone
# App 2: /Users/you/project-b → Android
# App 3: /Users/you/project-b → iPhone
```

**Behavior:**
```bash
cd /Users/you/project-b
flutter_skill inspect

# Output:
# 🔍 Found 2 Flutter apps running in the same location:
#    /Users/you/project-b
#
# 1. 📱 Android Emulator - Port 50001
# 2. 📱 iPhone 16 Pro - Port 50002
#
# Select app to connect (1-2): _
```

## Benefits

1. **Zero Ambiguity**: Always clear which app you're connecting to
2. **Device Context**: See which device each app is running on
3. **Fast Selection**: Focused UI showing only relevant differences
4. **Future Automation**: Support for `--device` flag to skip manual selection
5. **Robust Detection**: Multiple strategies to identify devices

## Testing

Run the device selection test:

```bash
dart run test_device_selection.dart
```

Expected output shows:
- Device detection results
- Smart selection with/without device filter
- Proper handling of multiple apps in same location

## Future Enhancements

1. **CLI Device Flag**
   ```bash
   flutter_skill inspect --device iPhone
   flutter_skill act tap btn1 --device Android
   ```

2. **Device Preference Caching**
   - Remember last selected device per project
   - Store in `.flutter_skill_prefs`

3. **Enhanced Device Detection**
   - Query `flutter devices` output
   - Match against device list for friendly names
   - Detect platform (iOS/Android/Web/Desktop) from device ID

4. **Smart Device Hints**
   - If only iOS app running, suggest iOS-specific commands
   - Warn if trying to test Android-specific feature on iOS device

## Implementation Files

- **[lib/src/process_based_discovery.dart](lib/src/process_based_discovery.dart)** - Device detection and smart selection
- **[test_device_selection.dart](test_device_selection.dart)** - Test script for device-aware selection
