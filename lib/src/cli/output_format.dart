import 'dart:io';

/// Returns true when the process is running inside a CI environment.
///
/// Checks common CI environment variables used by GitHub Actions, CircleCI,
/// Travis CI, Buildkite, and generic CI setups.
bool isCiEnvironment() =>
    Platform.environment.containsKey('CI') ||
    Platform.environment.containsKey('GITHUB_ACTIONS') ||
    Platform.environment.containsKey('CIRCLECI') ||
    Platform.environment.containsKey('TRAVIS') ||
    Platform.environment.containsKey('BUILDKITE');

/// The output format to use for CLI commands.
enum OutputFormat { human, json }

/// Resolve the output format from CLI args or environment.
///
/// [args] may contain `--output=json` or `--output=human`.
/// Falls back to [isCiEnvironment] when no explicit flag is provided.
OutputFormat resolveOutputFormat(List<String> args) {
  for (final arg in args) {
    if (arg == '--output=json') return OutputFormat.json;
    if (arg == '--output=human') return OutputFormat.human;
  }
  return isCiEnvironment() ? OutputFormat.json : OutputFormat.human;
}

/// Strip `--output=*` entries from an arg list.
List<String> stripOutputFormatFlag(List<String> args) =>
    args.where((a) => !a.startsWith('--output=')).toList();

/// Strip `--output=*` entries from an arg list.
///
/// Deprecated: use [stripOutputFormatFlag] for clarity.
List<String> stripOutputFlag(List<String> args) => stripOutputFormatFlag(args);

/// Parse `--server=<id>[,<id2>,...]` from args.
List<String> parseServerIds(List<String> args) {
  for (final arg in args) {
    if (arg.startsWith('--server=')) {
      final value = arg.substring('--server='.length);
      return value.split(',').map((s) => s.trim()).where((s) => s.isNotEmpty).toList();
    }
  }
  return [];
}

/// Holds the outcome of a single per-server parallel action.
class ServerCallResult {
  final String serverId;
  final bool success;
  final String? action;
  final Map<String, dynamic>? data;
  final String? error;
  final int durationMs;

  const ServerCallResult({
    required this.serverId,
    required this.success,
    this.action,
    this.data,
    this.error,
    required this.durationMs,
  });

  Map<String, dynamic> toJson() => {
        'server': serverId,
        'success': success,
        if (action != null) 'action': action,
        if (data != null) 'data': data,
        if (error != null) 'error': error,
        'duration_ms': durationMs,
      };
}
