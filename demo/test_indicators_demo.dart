/// Flutter Skill Test Indicators Demo
///
/// This script demonstrates visual indicators for test actions
///
/// Usage:
/// 1. Start this demo app: flutter run lib/demo/test_indicators_demo.dart
/// 2. Run the demo script: dart run demo/run_demo.dart
/// 3. Watch the visual indicators in action!

import 'package:flutter/material.dart';
import 'package:flutter_skill/flutter_skill.dart';

void main() {
  // Initialize Flutter Skill binding
  FlutterSkillBinding.ensureInitialized();

  runApp(const TestIndicatorsDemoApp());
}

class TestIndicatorsDemoApp extends StatelessWidget {
  const TestIndicatorsDemoApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Flutter Skill Test Indicators Demo',
      theme: ThemeData(
        primarySwatch: Colors.blue,
        useMaterial3: true,
      ),
      home: const DemoHomePage(),
    );
  }
}

class DemoHomePage extends StatefulWidget {
  const DemoHomePage({super.key});

  @override
  State<DemoHomePage> createState() => _DemoHomePageState();
}

class _DemoHomePageState extends State<DemoHomePage> {
  final _emailController = TextEditingController();
  final _passwordController = TextEditingController();
  String _status = 'Ready for demo';
  int _tapCount = 0;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Test Indicators Demo'),
        backgroundColor: Theme.of(context).colorScheme.inversePrimary,
      ),
      body: SingleChildScrollView(
        child: Padding(
          padding: const EdgeInsets.all(24.0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // Status Card
              Card(
                color: Colors.blue.shade50,
                child: Padding(
                  padding: const EdgeInsets.all(16.0),
                  child: Column(
                    children: [
                      const Icon(Icons.visibility, size: 48, color: Colors.blue),
                      const SizedBox(height: 8),
                      const Text(
                        'Visual Indicators Demo',
                        style: TextStyle(
                          fontSize: 20,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        _status,
                        style: const TextStyle(color: Colors.black54),
                        textAlign: TextAlign.center,
                      ),
                    ],
                  ),
                ),
              ),

              const SizedBox(height: 32),

              // Tap Demo Section
              const Text(
                '1. Tap Indicator',
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 8),
              const Text(
                'Tap these buttons to see expanding circle animations',
                style: TextStyle(color: Colors.black54),
              ),
              const SizedBox(height: 16),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                children: [
                  ElevatedButton(
                    key: const Key('button_1'),
                    onPressed: () {
                      setState(() {
                        _tapCount++;
                        _status = 'Button 1 tapped ($_tapCount times)';
                      });
                    },
                    child: const Text('Button 1'),
                  ),
                  ElevatedButton(
                    key: const Key('button_2'),
                    onPressed: () {
                      setState(() {
                        _tapCount++;
                        _status = 'Button 2 tapped ($_tapCount times)';
                      });
                    },
                    child: const Text('Button 2'),
                  ),
                  ElevatedButton(
                    key: const Key('button_3'),
                    onPressed: () {
                      setState(() {
                        _tapCount++;
                        _status = 'Button 3 tapped ($_tapCount times)';
                      });
                    },
                    child: const Text('Button 3'),
                  ),
                ],
              ),

              const SizedBox(height: 32),

              // Text Input Demo Section
              const Text(
                '2. Text Input Indicator',
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 8),
              const Text(
                'Type in these fields to see green border highlights',
                style: TextStyle(color: Colors.black54),
              ),
              const SizedBox(height: 16),
              TextField(
                key: const Key('email_field'),
                controller: _emailController,
                decoration: const InputDecoration(
                  labelText: 'Email',
                  border: OutlineInputBorder(),
                  prefixIcon: Icon(Icons.email),
                ),
                onChanged: (value) {
                  setState(() {
                    _status = 'Email entered: $value';
                  });
                },
              ),
              const SizedBox(height: 16),
              TextField(
                key: const Key('password_field'),
                controller: _passwordController,
                obscureText: true,
                decoration: const InputDecoration(
                  labelText: 'Password',
                  border: OutlineInputBorder(),
                  prefixIcon: Icon(Icons.lock),
                ),
                onChanged: (value) {
                  setState(() {
                    _status = 'Password entered';
                  });
                },
              ),

              const SizedBox(height: 32),

              // Long Press Demo Section
              const Text(
                '3. Long Press Indicator',
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 8),
              const Text(
                'Long press this button to see orange ring animation',
                style: TextStyle(color: Colors.black54),
              ),
              const SizedBox(height: 16),
              ElevatedButton(
                key: const Key('long_press_button'),
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.orange,
                  padding: const EdgeInsets.all(20),
                ),
                onPressed: () {
                  setState(() {
                    _status = 'Button pressed (try long press!)';
                  });
                },
                onLongPress: () {
                  setState(() {
                    _status = 'Long press detected!';
                  });
                },
                child: const Text('Long Press Me'),
              ),

              const SizedBox(height: 32),

              // Swipe Demo Section
              const Text(
                '4. Swipe Indicator',
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 8),
              const Text(
                'Swipe in this area to see purple arrow trails',
                style: TextStyle(color: Colors.black54),
              ),
              const SizedBox(height: 16),
              Container(
                key: const Key('swipe_area'),
                height: 200,
                decoration: BoxDecoration(
                  color: Colors.purple.shade50,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: Colors.purple.shade200, width: 2),
                ),
                child: const Center(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(Icons.swipe, size: 48, color: Colors.purple),
                      SizedBox(height: 8),
                      Text(
                        'Swipe Here',
                        style: TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.bold,
                          color: Colors.purple,
                        ),
                      ),
                      Text(
                        '↕️ Up/Down  ↔️ Left/Right',
                        style: TextStyle(color: Colors.black54),
                      ),
                    ],
                  ),
                ),
              ),

              const SizedBox(height: 32),

              // List for Drag Demo
              const Text(
                '5. Drag Indicator',
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 8),
              const Text(
                'Drag between these items to see movement trails',
                style: TextStyle(color: Colors.black54),
              ),
              const SizedBox(height: 16),
              ...List.generate(5, (index) {
                return Card(
                  key: Key('item_$index'),
                  margin: const EdgeInsets.only(bottom: 8),
                  child: ListTile(
                    leading: CircleAvatar(
                      child: Text('${index + 1}'),
                    ),
                    title: Text('Draggable Item ${index + 1}'),
                    subtitle: Text('Tap to select, drag to move'),
                    trailing: const Icon(Icons.drag_handle),
                    onTap: () {
                      setState(() {
                        _status = 'Item ${index + 1} selected';
                      });
                    },
                  ),
                );
              }),
            ],
          ),
        ),
      ),
    );
  }

  @override
  void dispose() {
    _emailController.dispose();
    _passwordController.dispose();
    super.dispose();
  }
}
