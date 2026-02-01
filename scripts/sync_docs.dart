#!/usr/bin/env dart

/// Syncs README.md and CHANGELOG.md to all distribution channels.
///
/// Usage: dart scripts/sync_docs.dart
///
/// This script:
/// 1. Copies README.md to vscode-extension/README.md
/// 2. Copies README.md to npm/README.md
/// 3. Converts README.md to HTML for IntelliJ plugin.xml description
/// 4. Converts CHANGELOG.md to HTML for IntelliJ plugin.xml change-notes

import 'dart:io';

void main() async {
  final projectRoot = Directory.current.path;

  print('📄 Syncing documentation...\n');

  // Read source files
  final readme = File('$projectRoot/README.md').readAsStringSync();
  final changelog = File('$projectRoot/CHANGELOG.md').readAsStringSync();

  // 1. Sync to VSCode extension
  print('📦 VSCode Extension...');
  File('$projectRoot/vscode-extension/README.md').writeAsStringSync(readme);
  print('   ✓ README.md copied');

  // 2. Sync to npm package
  print('📦 npm Package...');
  File('$projectRoot/npm/README.md').writeAsStringSync(readme);
  print('   ✓ README.md copied');

  // 3. Update IntelliJ plugin.xml
  print('📦 IntelliJ Plugin...');
  final pluginXmlPath =
      '$projectRoot/intellij-plugin/src/main/resources/META-INF/plugin.xml';
  final pluginXml = File(pluginXmlPath).readAsStringSync();

  final descriptionHtml = markdownToHtml(readme);
  final changeNotesHtml = changelogToHtml(changelog);

  final updatedPluginXml = updatePluginXml(
    pluginXml,
    descriptionHtml,
    changeNotesHtml,
  );

  File(pluginXmlPath).writeAsStringSync(updatedPluginXml);
  print('   ✓ plugin.xml updated with description and change-notes');

  print('\n✅ Documentation synced to all channels!');
}

/// Converts markdown to HTML for IntelliJ plugin description
String markdownToHtml(String markdown) {
  final lines = markdown.split('\n');
  final buffer = StringBuffer();
  var inCodeBlock = false;
  var inTable = false;
  var inList = false;

  for (var i = 0; i < lines.length; i++) {
    var line = lines[i];

    // Skip badges and images at the top
    if (line.startsWith('![') || line.contains('img.shields.io')) {
      continue;
    }

    // Code blocks
    if (line.startsWith('```')) {
      if (inCodeBlock) {
        buffer.writeln('</code></pre>');
        inCodeBlock = false;
      } else {
        buffer.writeln('<pre><code>');
        inCodeBlock = true;
      }
      continue;
    }

    if (inCodeBlock) {
      buffer.writeln(escapeHtml(line));
      continue;
    }

    // Tables
    if (line.startsWith('|')) {
      if (!inTable) {
        buffer.writeln('<table>');
        inTable = true;
      }

      // Skip separator line
      if (line.contains('---')) continue;

      final cells = line
          .split('|')
          .where((c) => c.trim().isNotEmpty)
          .map((c) => c.trim())
          .toList();

      if (cells.isEmpty) continue;

      // Check if this is header row (first row after table start)
      final isHeader = i > 0 &&
          !lines[i - 1].startsWith('|') &&
          !lines[i - 1].contains('---');

      buffer.write('<tr>');
      for (final cell in cells) {
        final tag = isHeader ? 'th' : 'td';
        buffer.write('<$tag>${formatInlineMarkdown(cell)}</$tag>');
      }
      buffer.writeln('</tr>');
      continue;
    } else if (inTable) {
      buffer.writeln('</table>');
      inTable = false;
    }

    // Headers
    if (line.startsWith('### ')) {
      if (inList) {
        buffer.writeln('</ul>');
        inList = false;
      }
      buffer.writeln('<h3>${formatInlineMarkdown(line.substring(4))}</h3>');
      continue;
    }
    if (line.startsWith('## ')) {
      if (inList) {
        buffer.writeln('</ul>');
        inList = false;
      }
      buffer.writeln('<h2>${formatInlineMarkdown(line.substring(3))}</h2>');
      continue;
    }
    if (line.startsWith('# ')) {
      if (inList) {
        buffer.writeln('</ul>');
        inList = false;
      }
      buffer.writeln('<h1>${formatInlineMarkdown(line.substring(2))}</h1>');
      continue;
    }

    // Blockquotes
    if (line.startsWith('> ')) {
      buffer.writeln(
          '<blockquote>${formatInlineMarkdown(line.substring(2))}</blockquote>');
      continue;
    }

    // Lists
    if (line.startsWith('- ') || line.startsWith('* ')) {
      if (!inList) {
        buffer.writeln('<ul>');
        inList = true;
      }
      buffer.writeln('<li>${formatInlineMarkdown(line.substring(2))}</li>');
      continue;
    }

    // Numbered lists
    if (RegExp(r'^\d+\. ').hasMatch(line)) {
      if (!inList) {
        buffer.writeln('<ol>');
        inList = true;
      }
      final content = line.replaceFirst(RegExp(r'^\d+\. '), '');
      buffer.writeln('<li>${formatInlineMarkdown(content)}</li>');
      continue;
    }

    // Close list if we hit empty line or non-list content
    if (inList && (line.trim().isEmpty || !line.startsWith(' '))) {
      buffer.writeln('</ul>');
      inList = false;
    }

    // Horizontal rule
    if (line.trim() == '---') {
      buffer.writeln('<hr/>');
      continue;
    }

    // Regular paragraphs
    if (line.trim().isNotEmpty) {
      buffer.writeln('<p>${formatInlineMarkdown(line)}</p>');
    }
  }

  // Close any open tags
  if (inTable) buffer.writeln('</table>');
  if (inList) buffer.writeln('</ul>');
  if (inCodeBlock) buffer.writeln('</code></pre>');

  return buffer.toString();
}

/// Converts changelog to HTML
String changelogToHtml(String changelog) {
  final lines = changelog.split('\n');
  final buffer = StringBuffer();
  var inList = false;

  for (final line in lines) {
    // Version headers
    if (line.startsWith('## ')) {
      if (inList) {
        buffer.writeln('</ul>');
        inList = false;
      }
      buffer.writeln('<h2>${line.substring(3)}</h2>');
      continue;
    }

    // Sub-headers
    if (line.startsWith('### ')) {
      if (inList) {
        buffer.writeln('</ul>');
        inList = false;
      }
      buffer.writeln('<h3>${line.substring(4)}</h3>');
      continue;
    }

    // List items
    if (line.startsWith('- ')) {
      if (!inList) {
        buffer.writeln('<ul>');
        inList = true;
      }
      buffer.writeln('<li>${formatInlineMarkdown(line.substring(2))}</li>');
      continue;
    }

    // Horizontal rule (section separator)
    if (line.trim() == '---') {
      if (inList) {
        buffer.writeln('</ul>');
        inList = false;
      }
      buffer.writeln('<hr/>');
      continue;
    }

    // Bold text lines (like **Major Feature Release**)
    if (line.startsWith('**') && line.endsWith('**')) {
      buffer.writeln('<p><b>${line.substring(2, line.length - 2)}</b></p>');
      continue;
    }

    // Close list on empty lines
    if (inList && line.trim().isEmpty) {
      buffer.writeln('</ul>');
      inList = false;
    }
  }

  if (inList) buffer.writeln('</ul>');

  return buffer.toString();
}

/// Formats inline markdown (bold, code, links)
String formatInlineMarkdown(String text) {
  var result = escapeHtml(text);

  // Bold
  result = result.replaceAllMapped(
    RegExp(r'\*\*(.+?)\*\*'),
    (m) => '<b>${m.group(1)}</b>',
  );

  // Inline code
  result = result.replaceAllMapped(
    RegExp(r'`([^`]+)`'),
    (m) => '<code>${m.group(1)}</code>',
  );

  // Links
  result = result.replaceAllMapped(
    RegExp(r'\[([^\]]+)\]\(([^)]+)\)'),
    (m) => '<a href="${m.group(2)}">${m.group(1)}</a>',
  );

  return result;
}

/// Escapes HTML special characters
String escapeHtml(String text) {
  return text
      .replaceAll('&', '&amp;')
      .replaceAll('<', '&lt;')
      .replaceAll('>', '&gt;');
}

/// Updates plugin.xml with new description and change-notes
String updatePluginXml(
  String pluginXml,
  String descriptionHtml,
  String changeNotesHtml,
) {
  // Update description
  var result = pluginXml.replaceAllMapped(
    RegExp(r'<description><!\[CDATA\[.*?\]\]></description>', dotAll: true),
    (m) => '<description><![CDATA[\n$descriptionHtml\n    ]]></description>',
  );

  // Update change-notes
  result = result.replaceAllMapped(
    RegExp(r'<change-notes><!\[CDATA\[.*?\]\]></change-notes>', dotAll: true),
    (m) => '<change-notes><![CDATA[\n$changeNotesHtml\n    ]]></change-notes>',
  );

  return result;
}
