import 'dart:io';
import 'package:flutter_skill/src/drivers/flutter_driver.dart';

void main(List<String> args) async {
  if (args.isEmpty) {
    print('Usage: dart run scripts/inspect_layout.dart <vm-uri>');
    exit(1);
  }

  String uri;
  try {
    uri = await FlutterSkillClient.resolveUri(args);
  } catch (e) {
    print(e);
    exit(1);
  }

  final client = FlutterSkillClient(uri);

  try {
    await client.connect();
    final tree = await client.getLayoutTree();

    // The tree can be huge. We need to print it recursively but summarized.
    print('Layout Widget Tree (Summary):');
    _printWidget(tree, '');
  } catch (e) {
    print('Error: $e');
    exit(1);
  } finally {
    await client.disconnect();
  }
}

void _printWidget(Map<String, dynamic> widget, String prefix) {
  // Typical inspect json structure:
  // { "description": "Column", "type": "_WidgetType", "children": [...] }
  // Or "summaryTree": true/false etc.

  // Checking typical format from devtools:
  // 'description' often holds the widget class name.
  final description = widget['description'] ?? 'Widget';

  // We can filter out some noise if needed
  print('$prefix- $description');

  if (widget.containsKey('children')) {
    final children = widget['children'];
    if (children is List) {
      for (final child in children) {
        if (child is Map<String, dynamic>) {
          _printWidget(child, '$prefix  ');
        }
      }
    }
  }
}
