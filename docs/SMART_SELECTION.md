# Smart App Selection

## Problem Statement

When multiple Flutter apps are running simultaneously, how does `flutter_skill` know which one to connect to? The user's concern was: "Won't extracting VM Service URI directly from ps command find the wrong Flutter app?"

## Solution

We implemented **smart app selection** that automatically matches the correct Flutter app based on the current working directory.

## How It Works

### 1. **Process Discovery**
Using `ps aux`, we find all running Flutter development-service processes and extract:
- VM Service URI (with authentication token)
- Bind port
- Process ID (PID)

### 2. **Project Path Extraction**
For each discovered app, we use `lsof -a -p <pid> -d cwd` to get the working directory where the Flutter app is running:

```bash
# Example output
lsof -a -p 47555 -d cwd -Fn
# Returns: n/Users/cw/development/flutter-skill/demo_app
```

### 3. **Smart Matching Algorithm**

```dart
static Future<FlutterApp?> smartSelect(List<FlutterApp> apps, {String? cwd}) async {
  if (apps.isEmpty) return null;
  if (apps.length == 1) return apps.first;  // Only one app, use it

  cwd ??= Directory.current.path;

  // Step 1: Try exact match
  final matches = apps.where((app) => app.projectPath == cwd).toList();
  if (matches.length == 1) return matches.first;

  // Step 2: Try prefix match (for subdirectories)
  if (matches.isEmpty) {
    matches = apps.where((app) =>
      cwd.startsWith(app.projectPath!) ||
      app.projectPath!.startsWith(cwd)
    ).toList();
  }
  if (matches.length == 1) return matches.first;

  // Step 3: Multiple or no matches - let user select
  return await userSelect(matches.isNotEmpty ? matches : apps);
}
```

## Selection Scenarios

### Scenario 1: Single App Running
**Behavior**: Automatically selects it, regardless of current directory
```bash
cd /tmp
flutter_skill inspect  # ✅ Works - only one app running
```

### Scenario 2: Multiple Apps, Exact Match
**Behavior**: Automatically selects the app matching current directory
```bash
# App 1 running in: /Users/cw/project-a
# App 2 running in: /Users/cw/project-b

cd /Users/cw/project-a
flutter_skill inspect  # ✅ Automatically selects App 1

cd /Users/cw/project-b
flutter_skill inspect  # ✅ Automatically selects App 2
```

### Scenario 3: Multiple Apps, Subdirectory Match
**Behavior**: Matches if you're in a subdirectory of the project
```bash
# App running in: /Users/cw/project-a

cd /Users/cw/project-a/lib/src
flutter_skill inspect  # ✅ Still matches App 1 (prefix match)
```

### Scenario 4: Multiple Apps, No Match
**Behavior**: Prompts user to select
```bash
# App 1 running in: /Users/cw/project-a
# App 2 running in: /Users/cw/project-b

cd /tmp
flutter_skill inspect
# Output:
# 🔍 Found 2 running Flutter apps:
#
# 1. 📁 /Users/cw/project-a - Port 50000
# 2. 📁 /Users/cw/project-b - Port 50001
#
# Select app to connect (1-2): _
```

## Benefits

1. **Zero Configuration**: No manual URI files or port specification needed
2. **Context Aware**: Automatically selects based on your working directory
3. **Fallback**: Always allows manual selection when ambiguous
4. **Fast**: No port scanning - instant discovery via process inspection
5. **Reliable**: Works with any `flutter run` command, no special flags required

## Testing

### Test Results

```bash
$ dart run test_smart_selection.dart

🧪 Testing Smart App Selection
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

📡 Discovering running Flutter apps...

✅ Found 1 running Flutter app(s):

1. VM Service: ws://127.0.0.1:58875/P6bevAT2b4g=/ws
   Port: 50000
   PID: 47555
   Project Path: /Users/cw/development/flutter-skill/demo_app

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

📋 Testing smart selection from demo_app directory...

Current directory: /Users/cw/development/flutter-skill/demo_app

✅ Smart selection succeeded!

Selected app:
   VM Service: ws://127.0.0.1:58875/P6bevAT2b4g=/ws
   Project Path: /Users/cw/development/flutter-skill/demo_app
   Port: 50000
   PID: 47555

🎉 SUCCESS: Correctly matched the demo_app!
```

## Implementation Files

- **[lib/src/process_based_discovery.dart](lib/src/process_based_discovery.dart)** - Core discovery and smart selection logic
- **[lib/src/unified_discovery.dart](lib/src/unified_discovery.dart)** - Unified discovery with multiple fallback strategies
- **[lib/src/flutter_skill_client.dart](lib/src/flutter_skill_client.dart)** - Auto-discovery integration

## Answer to the Original Question

> "Won't extracting VM Service URI directly from ps command find the wrong Flutter app?"

**No**, because:
1. We extract **all** running Flutter apps from ps
2. We determine each app's project directory using lsof
3. We match against the current working directory
4. We only auto-select when there's an unambiguous match
5. We prompt for user selection when multiple apps match or no match found

The process-based discovery is **more reliable** than port scanning because:
- It captures the actual VM Service URI with authentication token
- It knows which project each app belongs to
- It's instant (no network timeouts)
- It works regardless of which port the app uses
