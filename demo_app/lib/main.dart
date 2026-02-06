import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart'; // For kDebugMode
import 'package:flutter_skill/flutter_skill.dart';

void main() {
  // Only initialize FlutterSkill in debug mode
  // This ensures it's not included in release builds
  if (kDebugMode) {
    FlutterSkillBinding.ensureInitialized();
  }
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Flutter Skill Visual Demo',
      theme: ThemeData(primarySwatch: Colors.blue),
      home: const HomePage(),
    );
  }
}

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  final _textController = TextEditingController();
  String _status = 'Ready';

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Visual Indicators Test')),
      body: Padding(
        padding: const EdgeInsets.all(20.0),
        child: Column(
          children: [
            // Status display
            Container(
              padding: const EdgeInsets.all(16),
              color: Colors.blue[50],
              child: Text(_status, style: const TextStyle(fontSize: 18)),
            ),
            const SizedBox(height: 20),

            // Tap test buttons
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: [
                ElevatedButton(
                  key: const Key('btn1'),
                  onPressed: () => setState(() => _status = 'Button 1 clicked'),
                  child: const Text('Button 1'),
                ),
                ElevatedButton(
                  key: const Key('btn2'),
                  onPressed: () => setState(() => _status = 'Button 2 clicked'),
                  child: const Text('Button 2'),
                ),
              ],
            ),
            const SizedBox(height: 20),

            // Text input
            TextField(
              key: const Key('input'),
              controller: _textController,
              decoration: const InputDecoration(
                labelText: 'Test Input',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 20),

            // Long press button
            ElevatedButton(
              key: const Key('longpress'),
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.orange,
                padding: const EdgeInsets.all(20),
              ),
              onPressed: () => setState(() => _status = 'Pressed'),
              onLongPress: () => setState(() => _status = 'Long pressed!'),
              child: const Text('Long Press Me'),
            ),
            const SizedBox(height: 20),

            // Swipe area
            Container(
              key: const Key('swipe_area'),
              height: 150,
              color: Colors.purple[50],
              child: const Center(
                child: Text('Swipe Here', style: TextStyle(fontSize: 20)),
              ),
            ),
            const SizedBox(height: 20),

            // List items for drag
            Expanded(
              child: ListView.builder(
                itemCount: 5,
                itemBuilder: (context, i) => Card(
                  key: Key('item_$i'),
                  child: ListTile(
                    title: Text('Item $i'),
                    onTap: () => setState(() => _status = 'Item $i clicked'),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
