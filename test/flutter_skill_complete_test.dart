import 'dart:io';
import 'package:flutter_skill/src/flutter_skill_client.dart';

Future<void> main() async {
  final uri = 'ws://127.0.0.1:63420/I8U6V_Mzdsg=/ws';
  final client = FlutterSkillClient(uri);

  print('══════════════════════════════════════════════════════');
  print('Flutter Skill MCP 工具完整测试');
  print('══════════════════════════════════════════════════════');
  print('VM Service: $uri\n');

  try {
    // 1. 连接测试
    print('1. 测试连接...');
    await client.connect();
    print('   ✅ 连接成功\n');

    // 2. 获取可交互元素
    print('2. 获取可交互元素 (getInteractiveElements)...');
    final elements = await client.getInteractiveElements();
    print('   找到 ${elements.length} 个可交互元素:');
    for (final elem in elements) {
      print('   - ${elem['type']}: ${elem['key']} ${elem['text'] != null ? '"${elem['text']}"' : ""}');
    }
    print('');

    // 3. 获取 Widget Tree
    print('3. 获取 Widget Tree (getWidgetTree)...');
    final tree = await client.getWidgetTree(maxDepth: 5);
    final treeStr = tree.toString();
    print('   Widget Tree (前5层):');
    print('   ${treeStr.substring(0, treeStr.length > 500 ? 500 : treeStr.length)}...\n');

    // 4. 获取文本内容
    print('4. 获取所有文本内容 (getTextContent)...');
    final texts = await client.getTextContent();
    print('   找到 ${texts.length} 个文本元素:');
    for (final text in texts.take(5)) {
      print('   - "$text"');
    }
    if (texts.length > 5) print('   ...(共${texts.length}个)');
    print('');

    // 5. 截图测试
    print('5. 测试截图功能 (takeScreenshot)...');
    try {
      final screenshot = await client.takeScreenshot();
      if (screenshot != null) {
        print('   ✅ 截图成功，大小: ${screenshot.length} bytes');
        // 保存截图 (screenshot 是 base64 字符串)
        print('   💾 截图数据已获取\n');
      } else {
        print('   ⚠️  截图返回 null\n');
      }
    } catch (e) {
      print('   ❌ 截图失败: $e\n');
    }

    // 6. 获取当前路由
    print('6. 获取当前路由 (getCurrentRoute)...');
    try {
      final route = await client.getCurrentRoute();
      print('   当前路由: $route\n');
    } catch (e) {
      print('   ❌ 获取路由失败: $e\n');
    }

    // 7. 获取导航栈
    print('7. 获取导航栈 (getNavigationStack)...');
    try {
      final stack = await client.getNavigationStack();
      print('   导航栈: $stack\n');
    } catch (e) {
      print('   ❌ 获取导航栈失败: $e\n');
    }

    // 8. 获取日志
    print('8. 获取应用日志 (getLogs)...');
    try {
      final logs = await client.getLogs();
      print('   日志数量: ${logs.length}');
      if (logs.isNotEmpty) {
        print('   最新日志 (前3条):');
        for (final log in logs.take(3)) {
          print('   - $log');
        }
      }
      print('');
    } catch (e) {
      print('   ❌ 获取日志失败: $e\n');
    }

    // 9. 获取错误
    print('9. 获取运行时错误 (getErrors)...');
    try {
      final errors = await client.getErrors();
      print('   错误数量: ${errors.length}');
      if (errors.isNotEmpty) {
        print('   错误列表:');
        for (final error in errors.take(3)) {
          print('   - $error');
        }
      } else {
        print('   ✅ 无错误\n');
      }
    } catch (e) {
      print('   ❌ 获取错误失败: $e\n');
    }

    // 10. 获取性能数据
    print('10. 获取性能数据 (getPerformance)...');
    try {
      final perf = await client.getPerformance();
      print('   性能数据: $perf\n');
    } catch (e) {
      print('   ❌ 获取性能数据失败: $e\n');
    }

    // 11. 交互测试 - 只测试不会影响UI的操作
    if (elements.isNotEmpty) {
      final firstElem = elements.first;
      print('11. 交互测试 (tap) - 测试点击...');
      print('   准备点击: ${firstElem['key']}');
      try {
        await client.tap(key: firstElem['key']);
        print('   ✅ 点击成功\n');
      } catch (e) {
        print('   ❌ 点击失败: $e\n');
      }
    }

    // 12. Hot Reload 测试
    print('12. 测试 Hot Reload...');
    try {
      await client.hotReload();
      print('   ✅ Hot Reload 成功\n');
    } catch (e) {
      print('   ❌ Hot Reload 失败: $e\n');
    }

    print('══════════════════════════════════════════════════════');
    print('测试完成！');
    print('══════════════════════════════════════════════════════');
  } catch (e, stack) {
    print('❌ 测试过程中出错: $e');
    print('Stack: $stack');
    exit(1);
  } finally {
    await client.disconnect();
    print('\n✅ 已断开连接');
  }
}
