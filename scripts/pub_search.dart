import 'dart:convert';
import 'dart:io';
import 'package:http/http.dart' as http;

void main(List<String> args) async {
  if (args.isEmpty) {
    print('Usage: dart run scripts/pub_search.dart <query>');
    exit(1);
  }

  final query = args.join(' ');
  final url = Uri.parse('https://pub.dev/api/search?q=$query');

  try {
    final response = await http.get(url);
    if (response.statusCode != 200) {
      throw Exception('Failed to search pub.dev: ${response.statusCode}');
    }

    final json = jsonDecode(response.body);
    final packages = json['packages'] as List<dynamic>;

    if (packages.isEmpty) {
      print('No packages found for "$query"');
      exit(0);
    }

    print('Top packages for "$query":');
    // The search API returns just package names usually in 'package'.
    // We might need to fetch details for each, but let's just list them first.
    // Actually the standard API structure is { "packages": [ { "package": "name" }, ... ] }

    // To be useful to the Agent, we should probably fetch top 3 details
    // But for speed, let's list names first.

    var count = 0;
    for (final pkg in packages) {
      if (count++ >= 5) break;
      final name = pkg['package'];
      print('- $name');
      // Ideally we would fetch https://pub.dev/api/packages/$name to get description
      // Let's do a quick fetch for the top 1-2?
      if (count <= 3) {
        await _printPackageDetails(name);
      }
    }
  } catch (e) {
    print('Error: $e');
    exit(1);
  }
}

Future<void> _printPackageDetails(String name) async {
  try {
    final url = Uri.parse('https://pub.dev/api/packages/$name');
    final response = await http.get(url);
    if (response.statusCode == 200) {
      final json = jsonDecode(response.body);
      final latest = json['latest'];
      final pubspec = latest['pubspec'];
      final description = pubspec['description'] ?? '';
      final version = latest['version'];
      print('  Version: $version');
      print('  Description: $description');
    }
  } catch (e) {
    // ignore
  }
}
