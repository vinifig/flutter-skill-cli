import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

/// Detected platform type for native interactions
enum NativePlatform { iosSimulator, androidEmulator, unknown }

/// Result of a native platform operation
class NativeResult {
  final bool success;
  final String? message;
  final String? base64Image;
  final String? filePath;
  final Map<String, dynamic>? metadata;

  NativeResult({
    required this.success,
    this.message,
    this.base64Image,
    this.filePath,
    this.metadata,
  });

  Map<String, dynamic> toJson() => {
        'success': success,
        if (message != null) 'message': message,
        if (base64Image != null) 'image': base64Image,
        if (filePath != null) 'file_path': filePath,
        if (metadata != null) ...metadata!,
      };
}

/// Abstract driver for native platform interactions.
/// Enables interaction with native OS views that are invisible to Flutter's VM Service.
abstract class NativeDriver {
  NativePlatform get platform;

  Future<NativeResult> screenshot({bool saveToFile = true});
  Future<NativeResult> tap(double x, double y);
  Future<NativeResult> inputText(String text);
  Future<NativeResult> swipe(double startX, double startY, double endX,
      double endY,
      {int durationMs = 300});
  Future<Map<String, bool>> checkToolAvailability();

  /// Detect the platform from device_id or running environment
  static Future<NativePlatform> detectPlatform(String? deviceId) async {
    if (deviceId != null) {
      final lower = deviceId.toLowerCase();
      if (lower.contains('iphone') ||
          lower.contains('ipad') ||
          lower.contains('ios') ||
          lower.contains('simulator')) {
        return NativePlatform.iosSimulator;
      }
      if (lower.contains('android') ||
          lower.contains('emulator') ||
          lower.contains('pixel') ||
          lower.contains('sdk_gphone')) {
        return NativePlatform.androidEmulator;
      }
    }

    // Check if iOS Simulator is running
    try {
      final result =
          await Process.run('xcrun', ['simctl', 'list', 'devices', 'booted']);
      if (result.exitCode == 0 &&
          result.stdout.toString().contains('Booted')) {
        return NativePlatform.iosSimulator;
      }
    } catch (_) {}

    // Check if Android emulator is running
    try {
      final result = await Process.run('adb', ['devices']);
      if (result.exitCode == 0 &&
          result.stdout.toString().contains('emulator')) {
        return NativePlatform.androidEmulator;
      }
    } catch (_) {}

    return NativePlatform.unknown;
  }

  /// Create the appropriate driver for the detected platform
  static Future<NativeDriver?> create(String? deviceId) async {
    final platform = await detectPlatform(deviceId);
    switch (platform) {
      case NativePlatform.iosSimulator:
        return IosSimulatorDriver();
      case NativePlatform.androidEmulator:
        return AndroidEmulatorDriver();
      case NativePlatform.unknown:
        return null;
    }
  }
}

// =============================================================================
// iOS Simulator Driver
// =============================================================================

class _Point {
  final double x;
  final double y;
  _Point(this.x, this.y);
}

class IosSimulatorDriver extends NativeDriver {
  String? _cachedUdid;

  @override
  NativePlatform get platform => NativePlatform.iosSimulator;

  /// Get the UDID of the first booted simulator
  Future<String> _getBootedSimulatorUdid() async {
    if (_cachedUdid != null) return _cachedUdid!;
    final result = await Process.run(
      'xcrun',
      ['simctl', 'list', 'devices', 'booted', '-j'],
    );
    if (result.exitCode != 0) {
      throw Exception('No booted iOS Simulator found');
    }
    final json = jsonDecode(result.stdout as String);
    final devices = json['devices'] as Map<String, dynamic>;
    for (final runtime in devices.values) {
      for (final device in (runtime as List)) {
        if (device['state'] == 'Booted') {
          _cachedUdid = device['udid'] as String;
          return _cachedUdid!;
        }
      }
    }
    throw Exception('No booted iOS Simulator found');
  }

  @override
  Future<NativeResult> screenshot({bool saveToFile = true}) async {
    final udid = await _getBootedSimulatorUdid();
    final tempDir = Directory.systemTemp;
    final timestamp = DateTime.now().millisecondsSinceEpoch;
    final filePath = '${tempDir.path}/native_screenshot_$timestamp.png';

    final result = await Process.run(
      'xcrun',
      ['simctl', 'io', udid, 'screenshot', filePath],
    );

    if (result.exitCode != 0) {
      return NativeResult(
        success: false,
        message: 'Screenshot failed: ${result.stderr}',
      );
    }

    if (saveToFile) {
      return NativeResult(
        success: true,
        filePath: filePath,
        message: 'Native screenshot saved to $filePath',
      );
    }

    final bytes = await File(filePath).readAsBytes();
    final base64Image = base64.encode(bytes);
    await File(filePath).delete();
    return NativeResult(success: true, base64Image: base64Image);
  }

  @override
  Future<NativeResult> tap(double x, double y) async {
    // Map device pixel coordinates to screen coordinates for hit-testing
    final screenCoords = await _mapToScreenCoordinates(x, y);
    if (screenCoords == null) {
      return NativeResult(
        success: false,
        message:
            'Failed to map device coordinates to screen coordinates. '
            'Ensure the Simulator window is visible and not minimized.',
      );
    }

    // Use macOS Accessibility API to find the element at the target position
    // and perform AXPress action on it. This works reliably on macOS 26+
    // where synthetic mouse events (CGEvent) no longer trigger Simulator touches.
    final sx = screenCoords.x.toStringAsFixed(1);
    final sy = screenCoords.y.toStringAsFixed(1);

    final result = await Process.run('osascript', [
      '-e',
      '''
tell application "Simulator" to activate
delay 0.3
tell application "System Events"
    tell process "Simulator"
        -- Find the iOSContentGroup
        set contentGroup to missing value
        repeat with elem in UI elements of window 1
            try
                if subrole of elem is "iOSContentGroup" then
                    set contentGroup to elem
                    exit repeat
                end if
            end try
        end repeat

        if contentGroup is missing value then
            return "error:No iOSContentGroup found"
        end if

        -- Find the element at the target position by searching the accessibility tree.
        -- Prioritize specific roles (AXButton, AXTextField, etc.) over generic AXGroup,
        -- and prefer leaf elements (no children) as they are the actual interactive controls.
        set targetX to $sx
        set targetY to $sy
        set bestMatch to missing value
        set bestScore to -1

        set allElems to entire contents of contentGroup
        repeat with elem in allElems
            try
                set pos to position of elem
                set sz to size of elem
                set eLeft to item 1 of pos
                set eTop to item 2 of pos
                set eWidth to item 1 of sz
                set eHeight to item 2 of sz

                -- Check if target point is within this element's bounds
                if targetX >= eLeft and targetX <= (eLeft + eWidth) and targetY >= eTop and targetY <= (eTop + eHeight) then
                    set acts to name of actions of elem
                    if acts contains "AXPress" then
                        -- Score: higher = better match
                        -- Leaf elements (no children) get 1000 bonus
                        -- Specific roles (AXButton, AXTextField, etc.) get 500 bonus
                        -- Smaller area gets higher score (inverse area)
                        set area to eWidth * eHeight
                        set score to 0

                        set childCount to 0
                        try
                            set childCount to count of UI elements of elem
                        end try
                        if childCount is 0 then set score to score + 1000

                        set elemRole to role of elem
                        if elemRole is "AXButton" or elemRole is "AXTextField" or elemRole is "AXLink" or elemRole is "AXMenuItem" or elemRole is "AXCheckBox" or elemRole is "AXRadioButton" or elemRole is "AXSlider" then
                            set score to score + 500
                        end if

                        -- Smaller area = higher score (use inverse, max 499)
                        if area > 0 then
                            set areaScore to (100000 / area)
                            if areaScore > 499 then set areaScore to 499
                            set score to score + areaScore
                        end if

                        if score > bestScore then
                            set bestMatch to elem
                            set bestScore to score
                        end if
                    end if
                end if
            end try
        end repeat

        if bestMatch is missing value then
            return "error:No tappable element found at (" & targetX & ", " & targetY & ")"
        end if

        perform action "AXPress" of bestMatch
        set matchDesc to ""
        try
            set matchDesc to description of bestMatch
        end try
        set matchRole to ""
        try
            set matchRole to role of bestMatch
        end try
        return "ok:" & matchRole & " - " & matchDesc
    end tell
end tell
''',
    ]);

    if (result.exitCode != 0) {
      return NativeResult(
        success: false,
        message: 'Tap failed: ${result.stderr}',
      );
    }

    final output = (result.stdout as String).trim();
    if (output.startsWith('error:')) {
      return NativeResult(
        success: false,
        message: output.substring(6),
      );
    }

    final elementDesc = output.startsWith('ok:') ? output.substring(3) : '';
    return NativeResult(
      success: true,
      message:
          'Tapped at device (${x.round()}, ${y.round()}) -> element: $elementDesc',
      metadata: {
        'device_coords': {'x': x, 'y': y},
        'element': elementDesc,
      },
    );
  }

  @override
  Future<NativeResult> inputText(String text) async {
    final udid = await _getBootedSimulatorUdid();

    // Copy text to simulator pasteboard
    final process = await Process.start(
      'xcrun',
      ['simctl', 'pbcopy', udid],
    );
    process.stdin.write(text);
    await process.stdin.close();
    final exitCode = await process.exitCode;

    if (exitCode != 0) {
      return NativeResult(
        success: false,
        message: 'Failed to copy text to pasteboard',
      );
    }

    // Bring Simulator to front and paste using Cmd+V via AppleScript
    await Process.run('osascript', [
      '-e',
      'tell application "Simulator" to activate',
    ]);
    await Future.delayed(const Duration(milliseconds: 200));

    // Use System Events keystroke for Cmd+V (built-in, no external tools needed)
    final pasteResult = await Process.run('osascript', [
      '-e',
      'tell application "System Events" to keystroke "v" using command down',
    ]);

    if (pasteResult.exitCode != 0) {
      return NativeResult(
        success: false,
        message: 'Paste failed: ${pasteResult.stderr}',
      );
    }

    // Wait for potential iOS paste confirmation dialog and auto-accept it.
    // iOS 16+ shows "Allow Paste" dialog when pasting from external sources.
    await Future.delayed(const Duration(milliseconds: 500));
    await _dismissPasteDialog();

    return NativeResult(
      success: true,
      message: 'Entered text via pasteboard: "$text"',
    );
  }

  @override
  Future<NativeResult> swipe(
    double startX,
    double startY,
    double endX,
    double endY, {
    int durationMs = 300,
  }) async {
    // Determine scroll direction from the swipe vector
    final deltaY = endY - startY;

    // Map start coordinates to find the scrollable element
    final screenCoords = await _mapToScreenCoordinates(startX, startY);
    if (screenCoords == null) {
      return NativeResult(
        success: false,
        message: 'Failed to map coordinates',
      );
    }

    // Use accessibility scroll actions. If swiping up (deltaY < 0),
    // the content should scroll down (reveal content below).
    // AXScrollUpByPage scrolls content UP (user swipes up).
    final scrollAction = deltaY < 0 ? 'AXScrollUpByPage' : 'AXScrollDownByPage';
    final sx = screenCoords.x.toStringAsFixed(1);
    final sy = screenCoords.y.toStringAsFixed(1);

    final result = await Process.run('osascript', [
      '-e',
      '''
tell application "Simulator" to activate
delay 0.3
tell application "System Events"
    tell process "Simulator"
        set contentGroup to missing value
        repeat with elem in UI elements of window 1
            try
                if subrole of elem is "iOSContentGroup" then
                    set contentGroup to elem
                    exit repeat
                end if
            end try
        end repeat

        if contentGroup is missing value then
            return "error:No iOSContentGroup found"
        end if

        -- Find a scrollable element at the target position
        set targetX to $sx
        set targetY to $sy
        set scrollTarget to missing value

        set allElems to entire contents of contentGroup
        repeat with elem in allElems
            try
                set pos to position of elem
                set sz to size of elem
                set eLeft to item 1 of pos
                set eTop to item 2 of pos
                set eWidth to item 1 of sz
                set eHeight to item 2 of sz

                if targetX >= eLeft and targetX <= (eLeft + eWidth) and targetY >= eTop and targetY <= (eTop + eHeight) then
                    set acts to name of actions of elem
                    if acts contains "$scrollAction" then
                        set scrollTarget to elem
                        -- Don't break - keep looking for more specific (inner) scrollable element
                    end if
                end if
            end try
        end repeat

        if scrollTarget is missing value then
            return "error:No scrollable element found at (" & targetX & ", " & targetY & ")"
        end if

        perform action "$scrollAction" of scrollTarget
        return "ok:scrolled"
    end tell
end tell
''',
    ]);

    if (result.exitCode != 0) {
      return NativeResult(
        success: false,
        message: 'Swipe failed: ${result.stderr}',
      );
    }

    final output = (result.stdout as String).trim();
    if (output.startsWith('error:')) {
      return NativeResult(
        success: false,
        message: output.substring(6),
      );
    }

    return NativeResult(
      success: true,
      message:
          'Swiped from (${startX.round()},${startY.round()}) to (${endX.round()},${endY.round()})',
    );
  }

  @override
  Future<Map<String, bool>> checkToolAvailability() async {
    return {
      'xcrun_simctl': await _isCommandAvailable('xcrun'),
      'osascript': await _isCommandAvailable('osascript'),
    };
  }

  // ========== Paste Dialog Handling ==========

  /// Dismiss the iOS paste confirmation dialog if present.
  /// iOS 16+ shows "Allow Paste" when pasting from external sources.
  Future<void> _dismissPasteDialog() async {
    await Process.run('osascript', [
      '-e',
      '''
tell application "System Events"
    tell process "Simulator"
        set contentGroup to missing value
        repeat with elem in UI elements of window 1
            try
                if subrole of elem is "iOSContentGroup" then
                    set contentGroup to elem
                    exit repeat
                end if
            end try
        end repeat

        if contentGroup is missing value then return

        -- Search for "Allow Paste" button in the accessibility tree
        set allElems to entire contents of contentGroup
        repeat with elem in allElems
            try
                if role of elem is "AXButton" and description of elem is "Allow Paste" then
                    perform action "AXPress" of elem
                    return
                end if
            end try
        end repeat
    end tell
end tell
''',
    ]);
  }

  // ========== Coordinate Mapping ==========

  /// Map device pixel coordinates to macOS screen coordinates.
  /// Uses the iOSContentGroup accessibility element for precise bounds,
  /// and simctl screenshot for device pixel dimensions.
  Future<_Point?> _mapToScreenCoordinates(
      double deviceX, double deviceY) async {
    // Get content area position and size (always fresh, no caching
    // since the window can move between operations)
    final contentResult = await Process.run('osascript', [
      '-l',
      'JavaScript',
      '-e',
      '''
var app = Application("System Events");
var sim = app.processes.byName("Simulator");
var win = sim.windows[0];
var elems = win.uiElements();
var result = "notfound";
for (var i = 0; i < elems.length; i++) {
  try {
    if (elems[i].subrole() === "iOSContentGroup") {
      var pos = elems[i].position();
      var sz = elems[i].size();
      result = pos[0] + "," + pos[1] + "," + sz[0] + "," + sz[1];
      break;
    }
  } catch(e) {}
}
result;
''',
    ]);
    if (contentResult.exitCode != 0) return null;

    final contentStr = (contentResult.stdout as String).trim();
    if (contentStr == 'notfound') return null;

    final parts = contentStr.split(',');
    if (parts.length != 4) return null;
    final contentLeft = double.tryParse(parts[0]) ?? 0;
    final contentTop = double.tryParse(parts[1]) ?? 0;
    final contentWidth = double.tryParse(parts[2]) ?? 0;
    final contentHeight = double.tryParse(parts[3]) ?? 0;

    // Get device pixel resolution from simctl screenshot
    final udid = await _getBootedSimulatorUdid();
    final tempPath = '${Directory.systemTemp.path}/_coord_calibration.png';
    final ssResult = await Process.run(
      'xcrun',
      ['simctl', 'io', udid, 'screenshot', tempPath],
    );
    if (ssResult.exitCode != 0) return null;

    final file = File(tempPath);
    if (!await file.exists()) return null;
    final bytes = await file.readAsBytes();
    await file.delete();

    final dimensions = _readPngDimensions(bytes);
    if (dimensions == null) return null;

    // Calculate scale and map coordinates
    final scaleX = contentWidth / dimensions.x;
    final scaleY = contentHeight / dimensions.y;

    return _Point(
      contentLeft + (deviceX * scaleX),
      contentTop + (deviceY * scaleY),
    );
  }

  /// Read width and height from PNG IHDR chunk (bytes 16-23, big-endian)
  _Point? _readPngDimensions(Uint8List bytes) {
    if (bytes.length < 24) return null;
    if (bytes[0] != 0x89 ||
        bytes[1] != 0x50 ||
        bytes[2] != 0x4E ||
        bytes[3] != 0x47) {
      return null;
    }
    final width =
        (bytes[16] << 24 | bytes[17] << 16 | bytes[18] << 8 | bytes[19])
            .toDouble();
    final height =
        (bytes[20] << 24 | bytes[21] << 16 | bytes[22] << 8 | bytes[23])
            .toDouble();
    return _Point(width, height);
  }
}

// =============================================================================
// Android Emulator Driver
// =============================================================================

class AndroidEmulatorDriver extends NativeDriver {
  @override
  NativePlatform get platform => NativePlatform.androidEmulator;

  @override
  Future<NativeResult> screenshot({bool saveToFile = true}) async {
    final tempDir = Directory.systemTemp;
    final timestamp = DateTime.now().millisecondsSinceEpoch;
    final localPath = '${tempDir.path}/native_screenshot_$timestamp.png';
    const devicePath = '/sdcard/flutter_skill_screenshot.png';

    // Capture on device
    var result =
        await Process.run('adb', ['shell', 'screencap', '-p', devicePath]);
    if (result.exitCode != 0) {
      return NativeResult(
        success: false,
        message: 'Screenshot failed: ${result.stderr}',
      );
    }

    // Pull to local
    result = await Process.run('adb', ['pull', devicePath, localPath]);
    if (result.exitCode != 0) {
      return NativeResult(
        success: false,
        message: 'Failed to pull screenshot: ${result.stderr}',
      );
    }

    // Clean up device file
    await Process.run('adb', ['shell', 'rm', devicePath]);

    if (saveToFile) {
      return NativeResult(
        success: true,
        filePath: localPath,
        message: 'Native screenshot saved to $localPath',
      );
    }

    final bytes = await File(localPath).readAsBytes();
    final base64Image = base64.encode(bytes);
    await File(localPath).delete();
    return NativeResult(success: true, base64Image: base64Image);
  }

  @override
  Future<NativeResult> tap(double x, double y) async {
    final result = await Process.run(
      'adb',
      ['shell', 'input', 'tap', '${x.round()}', '${y.round()}'],
    );
    return NativeResult(
      success: result.exitCode == 0,
      message: result.exitCode == 0
          ? 'Tapped at (${x.round()}, ${y.round()})'
          : 'Tap failed: ${result.stderr}',
    );
  }

  @override
  Future<NativeResult> inputText(String text) async {
    // Escape special characters for adb shell input
    final escaped = text
        .replaceAll('\\', '\\\\')
        .replaceAll(' ', '%s')
        .replaceAll('&', '\\&')
        .replaceAll('<', '\\<')
        .replaceAll('>', '\\>')
        .replaceAll("'", "\\'")
        .replaceAll('"', '\\"');

    final result = await Process.run(
      'adb',
      ['shell', 'input', 'text', escaped],
    );
    return NativeResult(
      success: result.exitCode == 0,
      message: result.exitCode == 0
          ? 'Entered text: "$text"'
          : 'Text input failed: ${result.stderr}',
    );
  }

  @override
  Future<NativeResult> swipe(
    double startX,
    double startY,
    double endX,
    double endY, {
    int durationMs = 300,
  }) async {
    final result = await Process.run('adb', [
      'shell',
      'input',
      'swipe',
      '${startX.round()}',
      '${startY.round()}',
      '${endX.round()}',
      '${endY.round()}',
      '$durationMs',
    ]);
    return NativeResult(
      success: result.exitCode == 0,
      message: result.exitCode == 0
          ? 'Swiped from (${startX.round()},${startY.round()}) to (${endX.round()},${endY.round()})'
          : 'Swipe failed: ${result.stderr}',
    );
  }

  @override
  Future<Map<String, bool>> checkToolAvailability() async {
    return {
      'adb': await _isCommandAvailable('adb'),
    };
  }
}

// =============================================================================
// Shared Helpers
// =============================================================================

Future<bool> _isCommandAvailable(String command) async {
  try {
    final result = await Process.run('which', [command]);
    return result.exitCode == 0;
  } catch (_) {
    return false;
  }
}
