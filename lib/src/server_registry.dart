import 'dart:convert';
import 'dart:io';

/// A single named server instance entry stored in the registry.
class ServerEntry {
  final String id;
  final int port;
  final int pid;
  final String projectPath;
  final String deviceId;
  final String vmServiceUri;
  final DateTime startedAt;

  const ServerEntry({
    required this.id,
    required this.port,
    required this.pid,
    required this.projectPath,
    required this.deviceId,
    required this.vmServiceUri,
    required this.startedAt,
  });

  Map<String, dynamic> toJson() => {
        'id': id,
        'port': port,
        'pid': pid,
        'projectPath': projectPath,
        'deviceId': deviceId,
        'vmServiceUri': vmServiceUri,
        'startedAt': startedAt.toIso8601String(),
      };

  factory ServerEntry.fromJson(Map<String, dynamic> json) => ServerEntry(
        id: json['id'] as String,
        port: json['port'] as int,
        pid: json['pid'] as int,
        projectPath: json['projectPath'] as String? ?? '',
        deviceId: json['deviceId'] as String? ?? '',
        vmServiceUri: json['vmServiceUri'] as String? ?? '',
        startedAt: json['startedAt'] != null
            ? DateTime.parse(json['startedAt'] as String)
            : DateTime.now(),
      );
}

/// Manages ~/.flutter_skill/servers/ registry of named server instances.
class ServerRegistry {
  static Directory get _registryDir {
    final home = Platform.environment['HOME'] ??
        Platform.environment['USERPROFILE'] ??
        '.';
    final sep = Platform.pathSeparator;
    return Directory('$home${sep}.flutter_skill${sep}servers');
  }

  static File _entryFile(String id) =>
      File('${_registryDir.path}${Platform.pathSeparator}$id.json');

  static File _sockFile(String id) =>
      File('${_registryDir.path}${Platform.pathSeparator}$id.sock');

  /// Write a server entry to disk.
  ///
  /// Throws [ArgumentError] if the entry id contains characters that could
  /// be used for path traversal attacks.
  static Future<void> register(ServerEntry entry) async {
    if (!RegExp(r'^[a-zA-Z0-9_\-]+$').hasMatch(entry.id)) {
      throw ArgumentError(
          'Invalid server id "${entry.id}". Only letters, numbers, hyphens, and underscores are allowed.');
    }
    await _registryDir.create(recursive: true);
    await _entryFile(entry.id)
        .writeAsString(jsonEncode(entry.toJson()), flush: true);
  }

  /// Read a single server entry by ID. Returns null if not found.
  static Future<ServerEntry?> get(String id) async {
    final file = _entryFile(id);
    if (!await file.exists()) return null;
    try {
      final json =
          jsonDecode(await file.readAsString()) as Map<String, dynamic>;
      return ServerEntry.fromJson(json);
    } catch (_) {
      return null;
    }
  }

  /// Return all registered entries, filtering out stale ones (PID no longer alive).
  static Future<List<ServerEntry>> listAll() async {
    if (!await _registryDir.exists()) return [];

    final entries = <ServerEntry>[];
    await for (final entity in _registryDir.list()) {
      if (entity is! File) continue;
      if (!entity.path.endsWith('.json')) continue;
      try {
        final json =
            jsonDecode(await entity.readAsString()) as Map<String, dynamic>;
        final entry = ServerEntry.fromJson(json);
        // Filter stale entries — check if the process is still alive.
        if (await _isPidAlive(entry.pid)) {
          entries.add(entry);
        } else {
          // Clean up stale entry silently.
          await entity.delete().catchError((_) => entity);
        }
      } catch (_) {
        // Skip malformed files.
      }
    }
    return entries;
  }

  /// Delete a server entry (and its Unix socket file if present).
  static Future<void> unregister(String id) async {
    final file = _entryFile(id);
    if (await file.exists()) await file.delete();
    final sock = _sockFile(id);
    if (await sock.exists()) await sock.delete();
  }

  /// Check whether the TCP port for the named server is accepting connections.
  static Future<bool> isAlive(String id) async {
    final entry = await get(id);
    if (entry == null) return false;
    return await _isTcpPortOpen('127.0.0.1', entry.port);
  }

  /// Unix socket path for a server id, or null on Windows.
  static String? unixSocketPath(String id) {
    if (Platform.isWindows) return null;
    return _sockFile(id).path;
  }

  // ---------------------------------------------------------------------------
  // Helpers
  // ---------------------------------------------------------------------------

  static Future<bool> _isPidAlive(int pid) async {
    try {
      if (Platform.isWindows) {
        final result = await Process.run(
            'tasklist', ['/FI', 'PID eq $pid', '/NH'],
            runInShell: true);
        // Use word-boundary matching: PID column is space-padded in tasklist output.
        // A simple contains() would match PID 123 inside 1234.
        final output = result.stdout.toString();
        return output.split('\n').any((line) {
          final parts = line.trim().split(RegExp(r'\s+'));
          return parts.isNotEmpty && parts.any((p) => p == pid.toString());
        });
      } else {
        // kill -0 checks existence without sending a real signal.
        final result =
            await Process.run('kill', ['-0', pid.toString()], runInShell: true);
        return result.exitCode == 0;
      }
    } catch (_) {
      return false;
    }
  }

  static Future<bool> _isTcpPortOpen(String host, int port) async {
    try {
      final socket = await Socket.connect(host, port,
          timeout: const Duration(milliseconds: 500));
      await socket.close();
      return true;
    } catch (_) {
      return false;
    }
  }
}
