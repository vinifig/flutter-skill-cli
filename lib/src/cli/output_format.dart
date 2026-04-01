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
List<String> stripOutputFlag(List<String> args) =>
    args.where((a) => !a.startsWith('--output=')).toList();
