import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../bridge/bridge_protocol.dart';

/// Discovers bridge-protocol apps by scanning the bridge port range.
///
/// Each port is probed with an HTTP GET to [bridgeHealthPath].
/// Apps that respond with valid JSON are returned as [BridgeServiceInfo].
class BridgeDiscovery {
  /// Scan the default bridge port range and return all discovered apps.
  static Future<List<BridgeServiceInfo>> discoverAll({
    int portStart = bridgePortRangeStart,
    int portEnd = bridgePortRangeEnd,
    bool verbose = false,
  }) async {
    final results = <BridgeServiceInfo>[];
    final futures = <Future<BridgeServiceInfo?>>[];

    for (var port = portStart; port <= portEnd; port++) {
      futures.add(_probePort(port));
    }

    final probed = await Future.wait(futures);
    for (final info in probed) {
      if (info != null) {
        if (verbose) {
          print('   Found bridge app: $info');
        }
        results.add(info);
      }
    }

    return results;
  }

  /// Probe a single port. Returns [BridgeServiceInfo] or null.
  static Future<BridgeServiceInfo?> _probePort(int port) async {
    try {
      final client = HttpClient();
      client.connectionTimeout = const Duration(milliseconds: 500);

      final request =
          await client.get('127.0.0.1', port, bridgeHealthPath);
      final response = await request.close().timeout(
            const Duration(milliseconds: 800),
          );

      if (response.statusCode == 200) {
        final body = await response
            .transform(utf8.decoder)
            .join()
            .timeout(const Duration(milliseconds: 500));
        final json = jsonDecode(body) as Map<String, dynamic>;

        // Validate minimum fields
        if (json.containsKey('framework')) {
          client.close();
          return BridgeServiceInfo.fromHealthCheck(json, port);
        }
      }

      client.close();
    } catch (_) {
      // Port unavailable or not a bridge service
    }
    return null;
  }
}
