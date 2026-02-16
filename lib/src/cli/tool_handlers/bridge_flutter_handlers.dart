part of '../server.dart';

extension _BridgeFlutterHandlers on FlutterMcpServer {
  /// Handle bridge/Flutter platform tools (non-CDP, non-connection)
  Future<dynamic> _handleBridgeFlutterTool(String name, Map<String, dynamic> args, AppDriver? client) async {
    switch (name) {
      // Inspection
      case 'inspect':
        final elements = await client!.getInteractiveElements();
        final currentPageOnly = args['current_page_only'] ?? true;
        if (currentPageOnly) {
          final filtered = elements.where((e) {
            if (e is! Map) return true;
            final bounds = e['bounds'];
            if (bounds == null) return true;
            final x = bounds['x'] as int? ?? 0;
            final y = bounds['y'] as int? ?? 0;
            final visible = e['visible'] ?? true;
            // Exclude elements with negative coordinates (off-screen / background pages)
            return visible == true && x >= -10 && y >= -10;
          }).toList();
          return filtered;
        }
        return elements;
      case 'inspect_interactive':
        if (client is BridgeDriver) {
          return await client.getInteractiveElementsStructured();
        }
        final fc = _asFlutterClient(client!, 'inspect_interactive');
        return await fc.getInteractiveElementsStructured();
      case 'snapshot':
        final snapshotMode = args['mode'] as String? ?? 'text';
        if (snapshotMode == 'vision') {
          final imageBase64 = await client!.takeScreenshot(quality: 0.5, maxWidth: 800);
          if (imageBase64 == null) return {"success": false, "error": "Failed to capture screenshot"};
          final tempDir = Directory.systemTemp;
          final timestamp = DateTime.now().millisecondsSinceEpoch;
          final file = File('${tempDir.path}/flutter_skill_vision_$timestamp.png');
          await file.writeAsBytes(base64.decode(imageBase64));
          return {"mode": "vision", "path": file.path, "success": true};
        }
        final structured = await client!.getInteractiveElementsStructured();
        final snapshotElements = structured['elements'] as List<dynamic>? ?? [];
        
        // Also get all elements (including non-interactive) for richer snapshot
        List<dynamic> allElements = [];
        try {
          allElements = await client.getInteractiveElements();
        } catch (_) {
          // Fall back to interactive-only if full inspect fails
        }
        
        // Build text-based accessibility tree
        final buffer = StringBuffer();
        
        // Build interactive ref set for quick lookup
        final refSet = <String>{};
        for (final el in snapshotElements) {
          if (el is Map && el['ref'] != null) {
            refSet.add(el['ref'].toString());
          }
        }
        
        // Merge: interactive elements have refs, non-interactive are context
        final allMerged = <Map<String, dynamic>>[];
        
        // Add interactive elements with full data
        for (final el in snapshotElements) {
          if (el is Map<String, dynamic>) {
            allMerged.add({...el, '_interactive': true});
          }
        }
        
        // Add non-interactive elements from inspect (text, images, etc.)
        for (final el in allElements) {
          if (el is Map<String, dynamic>) {
            final isInteractive = el['clickable'] == true || 
                                  el['type']?.toString().contains('Button') == true ||
                                  el['type']?.toString().contains('TextField') == true ||
                                  el['type']?.toString().contains('Input') == true;
            if (!isInteractive) {
              allMerged.add({...el, '_interactive': false});
            }
          }
        }
        
        // Sort by position (top to bottom, left to right)
        allMerged.sort((a, b) {
          final aB = a['bounds'] as Map<String, dynamic>?;
          final bB = b['bounds'] as Map<String, dynamic>?;
          final ay = (aB?['y'] ?? 0) as num;
          final by = (bB?['y'] ?? 0) as num;
          if (ay != by) return ay.compareTo(by);
          final ax = (aB?['x'] ?? 0) as num;
          final bx = (bB?['x'] ?? 0) as num;
          return ax.compareTo(bx);
        });
        
        // Format as tree
        for (var i = 0; i < allMerged.length; i++) {
          final el = allMerged[i];
          final isLast = i == allMerged.length - 1;
          final prefix = isLast ? '└── ' : '├── ';
          final bounds = el['bounds'] as Map<String, dynamic>?;
          final bStr = bounds != null ? '(${bounds['x']},${bounds['y']} ${bounds['w']}x${bounds['h']})' : '';
          
          if (el['_interactive'] == true) {
            // Interactive element with ref
            final ref = el['ref'] ?? '';
            final text = el['text']?.toString() ?? '';
            final label = el['label']?.toString() ?? '';
            final value = el['value']?.toString();
            final enabled = el['enabled'] != false;
            final actions = (el['actions'] as List?)?.join(',') ?? '';
            
            String displayText = text.isNotEmpty ? text : label;
            if (displayText.length > 40) displayText = '${displayText.substring(0, 37)}...';
            
            final valuePart = value != null && value.isNotEmpty ? ' value="$value"' : '';
            final enabledPart = enabled ? '' : ' DISABLED';
            
            buffer.writeln('$prefix[$ref] "$displayText" $bStr$valuePart$enabledPart {$actions}');
          } else {
            // Non-interactive element (context)
            final type = el['type']?.toString() ?? 'unknown';
            final text = el['text']?.toString() ?? '';
            final shortType = type.replaceAll('RenderObjectToWidgetAdapter<RenderBox>', 'Root')
                                  .split('.').last;
            
            if (text.isNotEmpty) {
              String displayText = text;
              if (displayText.length > 50) displayText = '${displayText.substring(0, 47)}...';
              buffer.writeln('$prefix[$shortType] "$displayText" $bStr');
            }
            // Skip non-text non-interactive elements to keep snapshot compact
          }
        }
        
        final snapshotText = buffer.toString();
        final summary = structured['summary'] ?? '';
        
        final result = <String, dynamic>{
          'snapshot': snapshotText,
          'summary': summary,
          'elementCount': allMerged.length,
          'interactiveCount': snapshotElements.length,
          'tokenEstimate': snapshotText.length ~/ 4,
          'hint': 'Use ref IDs to interact: tap(ref: "button:Login"), enter_text(ref: "input:Email", text: "...")',
        };
        if (snapshotMode == 'smart') {
          final hasVisual = allMerged.any((el) {
            final type = (el['type'] ?? '').toString().toLowerCase();
            return type.contains('image') || type.contains('video') || type.contains('picture') || type.contains('icon');
          });
          if (hasVisual) {
            result['has_visual_content'] = true;
            result['hint'] = 'Use screenshot() if you need to verify images/visual layout. ' + (result['hint'] as String);
          }
        }
        return result;
      case 'get_widget_tree':
        final fc = _asFlutterClient(client!, 'get_widget_tree');
        final maxDepth = args['max_depth'] ?? 10;
        return await fc.getWidgetTree(maxDepth: maxDepth);
      case 'get_widget_properties':
        final fc = _asFlutterClient(client!, 'get_widget_properties');
        return await fc.getWidgetProperties(args['key']);
      case 'get_text_content':
        if (client is BridgeDriver) {
          final text = await client.getText();
          return {"success": true, "text": text};
        }
        final fc = _asFlutterClient(client!, 'get_text_content');
        return await fc.getTextContent();
      case 'find_by_type':
        final fc = _asFlutterClient(client!, 'find_by_type');
        return await fc.findByType(args['type']);

      // Basic Actions
      case 'tap':
        // Support three methods: key, text, or coordinates
        final x = args['x'] as num?;
        final y = args['y'] as num?;

        // Method 3: Tap by coordinates
        if (x != null && y != null) {
          if (client is BridgeDriver) {
            await client.callMethod('tap_at', {'x': x.toDouble(), 'y': y.toDouble()});
            return {"success": true, "method": "coordinates", "message": "Tapped at ($x, $y)", "position": {"x": x, "y": y}};
          }
          final fc = _asFlutterClient(client!, 'tap (coordinates)');
          await fc.tapAt(x.toDouble(), y.toDouble());
          return {
            "success": true,
            "method": "coordinates",
            "message": "Tapped at ($x, $y)",
            "position": {"x": x, "y": y},
          };
        }

        // Method 1 & 2: Tap by key, text, or semantic ref
        final result = await client!.tap(
          key: args['key'], 
          text: args['text'],
          ref: args['ref'],
        );
        if (result['success'] != true) {
          // Return full error details including suggestions
          return {
            "success": false,
            "error": result['error'] ?? {"message": "Element not found"},
            "target":
                result['target'] ?? {"key": args['key'], "text": args['text']},
            if (result['suggestions'] != null)
              "suggestions": result['suggestions'],
          };
        }
        return {
          "success": true,
          "method": args['key'] != null ? "key" : "text",
          "message": "Tapped",
          if (result['position'] != null) "position": result['position'],
        };

      case 'enter_text':
        final result = await client!.enterText(
          args['key'], 
          args['text'], 
          ref: args['ref'],
        );
        if (result['success'] != true) {
          return {
            "success": false,
            "error": result['error'] ?? {"message": "TextField not found"},
            "target": result['target'] ?? {"key": args['key']},
            if (result['suggestions'] != null)
              "suggestions": result['suggestions'],
          };
        }
        return {"success": true, "message": "Text entered"};

      case 'scroll_to':
        if (client is BridgeDriver) {
          await client.scroll(direction: args['direction'] ?? 'down', distance: args['distance'] ?? 300);
          return {"success": true, "message": "Scrolled"};
        }
        final fc = _asFlutterClient(client!, 'scroll_to');
        final result = await fc.scrollTo(key: args['key'], text: args['text']);
        if (result['success'] != true) {
          return {
            "success": false,
            "error": result['message'] ?? "Element not found",
          };
        }
        return {"success": true, "message": "Scrolled"};

      // Advanced Actions
      case 'long_press':
        if (client is BridgeDriver) {
          final success = await client.longPress(key: args['key'], text: args['text']);
          return success ? "Long pressed" : "Long press failed";
        }
        final fc = _asFlutterClient(client!, 'long_press');
        final duration = args['duration'] ?? 500;
        final success = await fc.longPress(
            key: args['key'], text: args['text'], duration: duration);
        return success ? "Long pressed" : "Long press failed";
      case 'double_tap':
        if (client is BridgeDriver) {
          final success = await client.doubleTap(key: args['key'], text: args['text']);
          return success ? "Double tapped" : "Double tap failed";
        }
        final fc = _asFlutterClient(client!, 'double_tap');
        final success =
            await fc.doubleTap(key: args['key'], text: args['text']);
        return success ? "Double tapped" : "Double tap failed";
      case 'swipe':
        final distance = (args['distance'] ?? 300).toDouble();
        final success = await client!.swipe(
            direction: args['direction'], distance: distance, key: args['key']);
        return success ? "Swiped ${args['direction']}" : "Swipe failed";
      case 'drag':
        if (client is BridgeDriver) {
          final result = await client.callMethod('drag', {'from_key': args['from_key'], 'to_key': args['to_key']});
          return result['success'] == true ? "Dragged" : "Drag failed";
        }
        final fc = _asFlutterClient(client!, 'drag');
        final success =
            await fc.drag(fromKey: args['from_key'], toKey: args['to_key']);
        return success ? "Dragged" : "Drag failed";

      // State & Validation
      case 'get_text_value':
        if (client is BridgeDriver) {
          final text = await client.getText(key: args['key']);
          return {"success": true, "text": text};
        }
        final fc = _asFlutterClient(client!, 'get_text_value');
        return await fc.getTextValue(args['key']);
      case 'get_checkbox_state':
        if (client is BridgeDriver) {
          return await client.callMethod('get_checkbox_state', {'key': args['key']});
        }
        final fc = _asFlutterClient(client!, 'get_checkbox_state');
        return await fc.getCheckboxState(args['key']);
      case 'get_slider_value':
        if (client is BridgeDriver) {
          return await client.callMethod('get_slider_value', {'key': args['key']});
        }
        final fc = _asFlutterClient(client!, 'get_slider_value');
        return await fc.getSliderValue(args['key']);
      case 'wait_for_element':
        if (client is BridgeDriver) {
          final timeout = args['timeout'] ?? 5000;
          final found = await client.waitForElement(key: args['key'], text: args['text'], timeout: timeout);
          return {"found": found};
        }
        final fc = _asFlutterClient(client!, 'wait_for_element');
        final timeout = args['timeout'] ?? 5000;
        final found = await fc.waitForElement(
            key: args['key'], text: args['text'], timeout: timeout);
        return {"found": found};
      case 'wait_for_gone':
        if (client is BridgeDriver) {
          final result = await client.callMethod('wait_for_gone', {'key': args['key'], 'text': args['text'], 'timeout': args['timeout'] ?? 5000});
          return {"gone": result['gone'] ?? true};
        }
        final fc = _asFlutterClient(client!, 'wait_for_gone');
        final timeout = args['timeout'] ?? 5000;
        final gone = await fc.waitForGone(
            key: args['key'], text: args['text'], timeout: timeout);
        return {"gone": gone};

      // Screenshot
      case 'screenshot':
        // Default to lower quality and max width to prevent token overflow
        final quality = (args['quality'] as num?)?.toDouble() ?? 0.8;
        final maxWidth = args['max_width'] as int? ?? 800;
        final saveToFile =
            args['save_to_file'] ?? false; // Return base64 by default for speed

        final imageBase64 =
            await client!.takeScreenshot(quality: quality, maxWidth: maxWidth);

        if (imageBase64 == null) {
          return {
            "success": false,
            "error": "Failed to capture screenshot",
            "message": "Screenshot returned null"
          };
        }

        if (saveToFile) {
          // Save to temporary file
          final tempDir = Directory.systemTemp;
          final timestamp = DateTime.now().millisecondsSinceEpoch;
          final filename = 'flutter_skill_screenshot_$timestamp.png';
          final file = File('${tempDir.path}/$filename');

          // Decode base64 and write to file
          final bytes = base64.decode(imageBase64);
          await file.writeAsBytes(bytes);

          return {
            "success": true,
            "file_path": file.path,
            "filename": filename,
            "size_bytes": bytes.length,
            "quality": quality,
            "max_width": maxWidth,
            "format": "png",
            "message": "Screenshot saved to ${file.path}"
          };
        } else {
          // Return base64 (legacy behavior)
          return {
            "image": imageBase64,
            "quality": quality,
            "max_width": maxWidth,
            "warning":
                "Returning base64 data. Consider using save_to_file=true for large images."
          };
        }

      case 'screenshot_region':
        if (client is BridgeDriver) {
          final result = await client.callMethod('screenshot_region', {
            'x': (args['x'] as num).toDouble(), 'y': (args['y'] as num).toDouble(),
            'width': (args['width'] as num).toDouble(), 'height': (args['height'] as num).toDouble(),
          });
          return result;
        }
        final fc = _asFlutterClient(client!, 'screenshot_region');
        final x = (args['x'] as num).toDouble();
        final y = (args['y'] as num).toDouble();
        final width = (args['width'] as num).toDouble();
        final height = (args['height'] as num).toDouble();
        final saveToFile = args['save_to_file'] ?? true;
        final image = await fc.takeRegionScreenshot(x, y, width, height);

        if (image == null) {
          return {
            "success": false,
            "error": "Failed to capture region screenshot",
          };
        }

        if (saveToFile) {
          final tempDir = Directory.systemTemp;
          final timestamp = DateTime.now().millisecondsSinceEpoch;
          final filename = 'flutter_skill_region_$timestamp.png';
          final file = File('${tempDir.path}/$filename');
          final bytes = base64.decode(image);
          await file.writeAsBytes(bytes);
          return {
            "success": true,
            "file_path": file.path,
            "size_bytes": bytes.length,
            "region": {"x": x, "y": y, "width": width, "height": height},
            "message": "Region screenshot saved to ${file.path}"
          };
        }

        return {
          "success": true,
          "image": image,
          "region": {"x": x, "y": y, "width": width, "height": height},
          "warning":
              "Returning base64 data. Consider using save_to_file=true for large regions."
        };

      // AI Visual Verification
      case 'visual_verify':
        final verifyQuality = (args['quality'] as num?)?.toDouble() ?? 0.5;
        final verifyDesc = args['description'] as String? ?? '';
        final checkElements = (args['check_elements'] as List?)?.cast<String>() ?? [];

        // Take screenshot
        final verifyImageBase64 = await client!.takeScreenshot(quality: verifyQuality, maxWidth: 800);
        String? verifyScreenshotPath;
        if (verifyImageBase64 != null) {
          final tempDir = Directory.systemTemp;
          final timestamp = DateTime.now().millisecondsSinceEpoch;
          final file = File('${tempDir.path}/flutter_skill_verify_$timestamp.png');
          await file.writeAsBytes(base64.decode(verifyImageBase64));
          verifyScreenshotPath = file.path;
        }

        // Take snapshot (text tree)
        String verifySnapshotText = '';
        List<String> foundElements = [];
        List<String> missingElements = [];
        int verifyElementCount = 0;
        try {
          final structured = await client!.getInteractiveElementsStructured();
          final snapshotElements = structured['elements'] as List<dynamic>? ?? [];
          verifyElementCount = snapshotElements.length;

          final buf = StringBuffer();
          for (var i = 0; i < snapshotElements.length; i++) {
            final el = snapshotElements[i] as Map<String, dynamic>;
            final ref = el['ref'] ?? '';
            final text = el['text']?.toString() ?? '';
            final label = el['label']?.toString() ?? '';
            final display = text.isNotEmpty ? text : label;
            buf.writeln('[$ref] "$display"');
          }
          verifySnapshotText = buf.toString();

          // Check elements
          if (checkElements.isNotEmpty) {
            final snapshotLower = verifySnapshotText.toLowerCase();
            for (final check in checkElements) {
              if (snapshotLower.contains(check.toLowerCase())) {
                foundElements.add(check);
              } else {
                missingElements.add(check);
              }
            }
          }
        } catch (e) {
          verifySnapshotText = 'Error getting snapshot: $e';
        }

        return {
          'success': true,
          'screenshot': verifyScreenshotPath,
          'snapshot': verifySnapshotText,
          'elements_found': foundElements,
          'elements_missing': missingElements,
          'element_count': verifyElementCount,
          'description_to_verify': verifyDesc,
          'hint': 'Compare the screenshot and snapshot against the description. Report any discrepancies.',
        };

      case 'visual_diff':
        final diffQuality = (args['quality'] as num?)?.toDouble() ?? 0.5;
        final baselinePath = args['baseline_path'] as String;
        final diffDesc = args['description'] as String? ?? '';

        final baselineFile = File(baselinePath);
        if (!await baselineFile.exists()) {
          return {'success': false, 'error': 'Baseline file not found: $baselinePath'};
        }

        final diffImageBase64 = await client!.takeScreenshot(quality: diffQuality, maxWidth: 800);
        String? currentScreenshotPath;
        if (diffImageBase64 != null) {
          final tempDir = Directory.systemTemp;
          final timestamp = DateTime.now().millisecondsSinceEpoch;
          final file = File('${tempDir.path}/flutter_skill_diff_$timestamp.png');
          await file.writeAsBytes(base64.decode(diffImageBase64));
          currentScreenshotPath = file.path;
        }

        String diffSnapshotText = '';
        try {
          final structured = await client!.getInteractiveElementsStructured();
          final els = structured['elements'] as List<dynamic>? ?? [];
          final buf = StringBuffer();
          for (final el in els) {
            if (el is Map<String, dynamic>) {
              final ref = el['ref'] ?? '';
              final text = el['text']?.toString() ?? '';
              final label = el['label']?.toString() ?? '';
              buf.writeln('[$ref] "${text.isNotEmpty ? text : label}"');
            }
          }
          diffSnapshotText = buf.toString();
        } catch (e) {
          diffSnapshotText = 'Error: $e';
        }

        return {
          'success': true,
          'baseline_path': baselinePath,
          'current_screenshot': currentScreenshotPath,
          'current_snapshot': diffSnapshotText,
          'description': diffDesc,
          'hint': 'Compare the baseline screenshot with the current screenshot. Look for visual differences. The text snapshot shows the current UI structure.',
        };

      case 'screenshot_element':
        // Support both key and text parameters
        String? targetKey = args['key'];

        // If text is provided, find the element first
        if (targetKey == null && args['text'] != null) {
          final elements = await client!.getInteractiveElements();
          final matchingElement = elements.firstWhere(
            (e) => e['text'] == args['text'],
            orElse: () => <String, dynamic>{},
          );
          targetKey = matchingElement['key'];
        }

        if (targetKey == null) {
          return {
            "error": "Element not found",
            "message":
                "No element found with key or text: ${args['key'] ?? args['text']}",
          };
        }

        if (client is BridgeDriver) {
          final result = await client.callMethod('screenshot_element', {'key': targetKey});
          return result;
        }
        final fc = _asFlutterClient(client!, 'screenshot_element');
        final image = await fc.takeElementScreenshot(targetKey);
        if (image == null) {
          return {
            "error": "Screenshot failed",
            "message": "Could not capture screenshot of element",
          };
        }
        return {"image": image};

      // Navigation
      case 'get_current_route':
        if (client is BridgeDriver) {
          final route = await client.getRoute();
          return {"route": route};
        }
        final fc = _asFlutterClient(client!, 'get_current_route');
        return await fc.getCurrentRoute();
      case 'go_back':
        if (client is BridgeDriver) {
          final success = await client.goBack();
          return success ? "Navigated back" : "Cannot go back";
        }
        final fc = _asFlutterClient(client!, 'go_back');
        final success = await fc.goBack();
        return success ? "Navigated back" : "Cannot go back";
      case 'get_navigation_stack':
        if (client is BridgeDriver) {
          return await client.callMethod('get_navigation_stack');
        }
        final fc = _asFlutterClient(client!, 'get_navigation_stack');
        return await fc.getNavigationStack();

      // Debug & Logs
      case 'get_logs':
        final logs = await client!.getLogs();
        return {
          "logs": logs,
          "summary": {
            "total_count": logs.length,
            "message": "${logs.length} log entries"
          }
        };
      case 'get_errors':
        if (client is BridgeDriver) {
          return await client.callMethod('get_errors', {'limit': args['limit'] ?? 50, 'offset': args['offset'] ?? 0});
        }
        final fc = _asFlutterClient(client!, 'get_errors');
        final allErrors = await fc.getErrors();
        final limit = int.tryParse('${args['limit'] ?? ''}') ?? 50;
        final offset = int.tryParse('${args['offset'] ?? ''}') ?? 0;
        final pagedErrors = allErrors.skip(offset).take(limit).toList();
        return {
          "errors": pagedErrors,
          "summary": {
            "total_count": allErrors.length,
            "returned_count": pagedErrors.length,
            "offset": offset,
            "limit": limit,
            "has_more": offset + limit < allErrors.length,
            "has_errors": allErrors.isNotEmpty,
            "message": allErrors.isEmpty
                ? "No errors found"
                : "${allErrors.length} error(s) total, showing ${pagedErrors.length} (offset: $offset)"
          }
        };
      case 'clear_logs':
        await client!.clearLogs();
        return {"success": true, "message": "Logs cleared successfully"};
      case 'get_performance':
        if (client is BridgeDriver) {
          return await client.callMethod('get_performance');
        }
        final fc = _asFlutterClient(client!, 'get_performance');
        return await fc.getPerformance();

      // === HTTP / Network Monitoring ===
      case 'enable_network_monitoring':
        if (client is BridgeDriver) {
          return await client.callMethod('enable_network_monitoring', {'enable': args['enable'] ?? true});
        }
        final fc = _asFlutterClient(client!, 'enable_network_monitoring');
        final enable = args['enable'] ?? true;
        final success = await fc.enableHttpTimelineLogging(enable: enable);
        return {
          "success": success,
          "enabled": enable,
          "message": success
              ? "HTTP monitoring ${enable ? 'enabled' : 'disabled'}"
              : "Failed to enable HTTP monitoring (VM Service extension not available)",
          "usage": enable
              ? "Now perform actions, then call get_network_requests() to see API calls"
              : null,
        };

      case 'get_network_requests':
        if (client is BridgeDriver) {
          return await client.callMethod('get_network_requests', {'limit': args['limit'] ?? 20});
        }
        final fc = _asFlutterClient(client!, 'get_network_requests');
        final limit = int.tryParse('${args['limit'] ?? ''}') ?? 20;
        // Try VM Service HTTP profile first (captures all dart:io HTTP)
        final profile = await fc.getHttpProfile();
        if (profile.containsKey('requests') && !profile.containsKey('error')) {
          final allRequests = (profile['requests'] as List?) ?? [];
          // Take latest N requests, format for readability
          final recentRequests = allRequests.length > limit
              ? allRequests.sublist(allRequests.length - limit)
              : allRequests;

          final formatted = recentRequests.map((r) {
            if (r is Map) {
              return {
                'id': r['id'],
                'method': r['method'],
                'uri': r['uri'],
                'status_code': r['response']?['statusCode'],
                'start_time': r['startTime'] != null
                    ? DateTime.fromMicrosecondsSinceEpoch(r['startTime'])
                        .toIso8601String()
                    : null,
                'end_time': r['endTime'] != null
                    ? DateTime.fromMicrosecondsSinceEpoch(r['endTime'])
                        .toIso8601String()
                    : null,
                'duration_ms': (r['endTime'] != null && r['startTime'] != null)
                    ? ((r['endTime'] - r['startTime']) / 1000).round()
                    : null,
                'content_type':
                    r['response']?['headers']?['content-type']?.toString(),
              };
            }
            return r;
          }).toList();

          return {
            "success": true,
            "source": "vm_service_http_profile",
            "requests": formatted,
            "total": allRequests.length,
            "returned": formatted.length,
            "message":
                "${formatted.length} of ${allRequests.length} HTTP requests"
          };
        }

        // Fallback: try manually logged requests from the binding
        final manualRequests = await fc.getHttpRequests(limit: limit);
        return {
          "success": true,
          "source": "manual_log",
          ...manualRequests,
          "hint":
              "For automatic HTTP capture, call enable_network_monitoring() first"
        };

      case 'clear_network_requests':
        if (client is BridgeDriver) {
          return await client.callMethod('clear_network_requests');
        }
        final fc = _asFlutterClient(client!, 'clear_network_requests');
        await fc.clearHttpRequests();
        return {"success": true, "message": "Network request history cleared"};

      // === NEW: Batch Operations ===
      case 'execute_batch':
        if (client is BridgeDriver) {
          final actions = args['actions'] as List? ?? [];
          final results = <Map<String, dynamic>>[];
          for (final action in actions) {
            if (action is Map<String, dynamic>) {
              final toolName = action['tool'] as String?;
              final toolArgs = Map<String, dynamic>.from(action['args'] as Map? ?? {});
              if (toolName != null) {
                try {
                  final result = await client.callMethod(toolName, toolArgs);
                  results.add({'tool': toolName, 'success': true, 'result': result});
                } catch (e) {
                  results.add({'tool': toolName, 'success': false, 'error': e.toString()});
                }
              }
            }
          }
          return {"success": true, "results": results, "count": results.length};
        }
        final fc = _asFlutterClient(client!, 'execute_batch');
        return await _executeBatch(args, fc);

      // === NEW: Coordinate-based Actions ===
      case 'tap_at':
        if (client is BridgeDriver) {
          await client.callMethod('tap_at', {'x': (args['x'] as num).toDouble(), 'y': (args['y'] as num).toDouble()});
          return {"success": true, "action": "tap_at", "x": args['x'], "y": args['y']};
        }
        final fc = _asFlutterClient(client!, 'tap_at');
        final x = (args['x'] as num).toDouble();
        final y = (args['y'] as num).toDouble();
        await fc.tapAt(x, y);
        return {"success": true, "action": "tap_at", "x": x, "y": y};

      case 'long_press_at':
        if (client is BridgeDriver) {
          await client.callMethod('long_press_at', {'x': (args['x'] as num).toDouble(), 'y': (args['y'] as num).toDouble(), 'duration': args['duration'] ?? 500});
          return {"success": true, "action": "long_press_at", "x": args['x'], "y": args['y']};
        }
        final fc = _asFlutterClient(client!, 'long_press_at');
        final x = (args['x'] as num).toDouble();
        final y = (args['y'] as num).toDouble();
        final duration = args['duration'] ?? 500;
        await fc.longPressAt(x, y, duration: duration);
        return {"success": true, "action": "long_press_at", "x": x, "y": y};

      case 'swipe_coordinates':
        if (client is BridgeDriver) {
          await client.callMethod('swipe_coordinates', {
            'start_x': ((args['start_x'] ?? args['startX']) as num).toDouble(),
            'start_y': ((args['start_y'] ?? args['startY']) as num).toDouble(),
            'end_x': ((args['end_x'] ?? args['endX']) as num).toDouble(),
            'end_y': ((args['end_y'] ?? args['endY']) as num).toDouble(),
            'duration': args['duration'] ?? args['durationMs'] ?? 300,
          });
          return {"success": true, "action": "swipe_coordinates"};
        }
        final fc = _asFlutterClient(client!, 'swipe_coordinates');
        final startX = ((args['start_x'] ?? args['startX']) as num).toDouble();
        final startY = ((args['start_y'] ?? args['startY']) as num).toDouble();
        final endX = ((args['end_x'] ?? args['endX']) as num).toDouble();
        final endY = ((args['end_y'] ?? args['endY']) as num).toDouble();
        final duration = args['duration'] ?? 300;
        await fc.swipeCoordinates(startX, startY, endX, endY,
            duration: duration);
        return {"success": true, "action": "swipe_coordinates"};

      case 'edge_swipe':
        if (client is BridgeDriver) {
          return await client.callMethod('edge_swipe', {'edge': args['edge'], 'direction': args['direction'], 'distance': (args['distance'] as num?)?.toDouble() ?? 200});
        }
        final fc = _asFlutterClient(client!, 'edge_swipe');
        final edge = args['edge'] as String;
        final direction = args['direction'] as String;
        final distance = (args['distance'] as num?)?.toDouble() ?? 200;
        final result = await fc.edgeSwipe(
            edge: edge, direction: direction, distance: distance);
        return result;

      case 'gesture':
        if (client is BridgeDriver) {
          return await client.callMethod('gesture', args);
        }
        final fc = _asFlutterClient(client!, 'gesture');
        return await _performGesture(args, fc);

      case 'wait_for_idle':
        if (client is BridgeDriver) {
          return {"success": true, "message": "Bridge platform ready"};
        }
        final fc = _asFlutterClient(client!, 'wait_for_idle');
        return await _waitForIdle(args, fc);

      // === NEW: Smart Scroll ===
      case 'scroll_until_visible':
        if (client is BridgeDriver) {
          return await client.callMethod('scroll_until_visible', {'key': args['key'], 'text': args['text'], 'direction': args['direction'] ?? 'down', 'max_scrolls': args['max_scrolls'] ?? 10});
        }
        final fc = _asFlutterClient(client!, 'scroll_until_visible');
        return await _scrollUntilVisible(args, fc);

      // === Batch Assertions ===
      case 'assert_batch':
        final assertions = (args['assertions'] as List<dynamic>?) ?? [];
        final results = <Map<String, dynamic>>[];
        int passed = 0;
        int failed = 0;
        for (final assertion in assertions) {
          final a = assertion as Map<String, dynamic>;
          final aType = a['type'] as String;
          try {
            final toolName = aType == 'visible' ? 'assert_visible'
                : aType == 'not_visible' ? 'assert_not_visible'
                : aType == 'text' ? 'assert_text'
                : aType == 'element_count' ? 'assert_element_count'
                : aType;
            final toolArgs = <String, dynamic>{
              if (a['key'] != null) 'key': a['key'],
              if (a['text'] != null) 'text': a['text'],
              if (a['expected'] != null) 'expected': a['expected'],
              if (a['count'] != null) 'expected_count': a['count'],
            };
            final result = await _executeToolInner(toolName, toolArgs);
            final success = result is Map && result['success'] == true;
            if (success) passed++; else failed++;
            results.add({'type': aType, 'success': success, 'result': result});
          } catch (e) {
            failed++;
            results.add({'type': aType, 'success': false, 'error': e.toString()});
          }
        }
        return {
          'success': failed == 0,
          'total': assertions.length,
          'passed': passed,
          'failed': failed,
          'results': results,
        };

      // === NEW: Assertions ===
      case 'assert_visible':
        if (client is BridgeDriver) {
          final found = await client.findElement(key: args['key'], text: args['text']);
          final isVisible = found.isNotEmpty && found['found'] == true;
          return {"success": isVisible, "visible": isVisible, "message": isVisible ? "Element is visible" : "Element not found"};
        }
        final fc = _asFlutterClient(client!, 'assert_visible');
        return await _assertVisible(args, fc, shouldBeVisible: true);

      case 'assert_not_visible':
        if (client is BridgeDriver) {
          final found = await client.findElement(key: args['key'], text: args['text']);
          final isGone = found.isEmpty || found['found'] != true;
          return {"success": isGone, "visible": !isGone, "message": isGone ? "Element is not visible" : "Element is still visible"};
        }
        final fc = _asFlutterClient(client!, 'assert_not_visible');
        return await _assertVisible(args, fc, shouldBeVisible: false);

      case 'assert_text':
        if (client is BridgeDriver) {
          final actual = await client.getText(key: args['key']);
          final expected = args['expected'] as String?;
          final matches = actual == expected;
          return {"success": matches, "actual": actual, "expected": expected, "message": matches ? "Text matches" : "Text mismatch"};
        }
        final fc = _asFlutterClient(client!, 'assert_text');
        return await _assertText(args, fc);

      case 'assert_element_count':
        if (client is BridgeDriver) {
          final elements = await client.getInteractiveElements();
          final count = elements.length;
          final expected = args['expected'] as int?;
          final matches = expected == null || count == expected;
          return {"success": matches, "count": count, "expected": expected, "message": matches ? "Count matches" : "Expected $expected but found $count"};
        }
        final fc = _asFlutterClient(client!, 'assert_element_count');
        return await _assertElementCount(args, fc);

      // === NEW: Page State ===
      case 'get_page_state':
        if (client is BridgeDriver) {
          final route = await client.getRoute();
          final structured = await client.getInteractiveElementsStructured();
          return {"route": route, "elements": structured};
        }
        final fc = _asFlutterClient(client!, 'get_page_state');
        return await _getPageState(fc);

      case 'get_interactable_elements':
        final includePositions = args['include_positions'] ?? true;
        return await client!
            .getInteractiveElements(includePositions: includePositions);

      // === NEW: Performance & Memory ===
      case 'get_frame_stats':
        if (client is BridgeDriver) {
          return await client.callMethod('get_frame_stats');
        }
        final fc = _asFlutterClient(client!, 'get_frame_stats');
        return await fc.getFrameStats();

      case 'get_memory_stats':
        if (client is BridgeDriver) {
          return await client.callMethod('get_memory_stats');
        }
        final fc = _asFlutterClient(client!, 'get_memory_stats');
        return await fc.getMemoryStats();

      // === Smart Diagnosis ===
      case 'diagnose':
        if (client is BridgeDriver) {
          return await client.callMethod('diagnose', args);
        }
        final fc = _asFlutterClient(client!, 'diagnose');
        return await _performDiagnosis(args, fc);

      case 'list_plugins':
        return {
          'plugins': _pluginTools.map((p) => {
            'name': p['name'],
            'description': p['description'],
            'steps': (p['steps'] as List).length,
            'source': p['source'],
          }).toList(),
          'count': _pluginTools.length,
        };

      case 'generate_report':
        return await _generateReport(args);

      default:
        // Check plugin tools
        final plugin = _pluginTools.cast<Map<String, dynamic>?>().firstWhere(
          (p) => p!['name'] == name,
          orElse: () => null,
        );
        if (plugin != null) {
          return await _executePlugin(plugin, args);
        }

        // AppMCP: discover/call tools on bridge platforms
        if (name == 'discover_page_tools' && _client is BridgeDriver) {
          return await (_client as BridgeDriver).discoverTools();
        }
        if (name == 'call_page_tool' && _client is BridgeDriver) {
          final toolName = args['name'] as String? ?? '';
          final toolParams = (args['params'] as Map<String, dynamic>?) ?? {};
          return await (_client as BridgeDriver).callTool(toolName, toolParams);
        }

        throw Exception("Unknown tool: $name");
    }
  }
}
