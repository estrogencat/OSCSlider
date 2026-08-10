import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:multicast_dns/multicast_dns.dart';

import 'param_control.dart';

const _oscJsonServiceType = '_oscjson._tcp.local';

// dart:io on Windows doesn't support SO_REUSEPORT, but multicast_dns always
// requests reusePort: true. Override the socket factory to drop that flag.
Future<RawDatagramSocket> _bindWithoutReusePort(
  dynamic host,
  int port, {
  bool reuseAddress = true,
  bool reusePort = true,
  int ttl = 1,
}) {
  return RawDatagramSocket.bind(
    host,
    port,
    reuseAddress: reuseAddress,
    reusePort: false,
    ttl: ttl,
  );
}

// mDNS multicast addresses per RFC 6762 - fixed, not exported by the package.
final _mdnsAddressIPv4 = InternetAddress('224.0.0.251');
final _mdnsAddressIPv6 = InternetAddress('FF02::FB');

// Windows boxes often have virtual adapters (VPN, Hyper-V, loopback) that
// throw when you try to join a multicast group on them. Probe each interface
// ourselves first and only hand the package the ones that actually work.
// probed concurrently, not one at a time - a box with a lot of virtual
// adapters (VR/streaming software tends to install several) can otherwise
// take long enough sequentially to blow past the mDNS package's own ~5s
// internal start() budget and surface as a raw TimeoutException.
Future<Iterable<NetworkInterface>> _joinableInterfacesFactory(InternetAddressType type) async {
  final all = await NetworkInterface.list(includeLinkLocal: true, type: type);
  final mdnsAddress = type == InternetAddressType.IPv6 ? _mdnsAddressIPv6 : _mdnsAddressIPv4;

  Future<NetworkInterface?> probe(NetworkInterface iface) async {
    if (iface.addresses.isEmpty) return null;
    RawDatagramSocket? socket;
    try {
      socket = await RawDatagramSocket.bind(
        type == InternetAddressType.IPv6 ? InternetAddress.anyIPv6 : InternetAddress.anyIPv4,
        0,
      );
      socket.joinMulticast(mdnsAddress, iface);
      return iface;
    } catch (_) {
      // interface doesn't support multicast - skip it.
      return null;
    } finally {
      socket?.close();
    }
  }

  final probed = await Future.wait(all.map(probe));
  return probed.whereType<NetworkInterface>();
}

class DiscoveredParam {
  final String name;
  final ParamType type;

  DiscoveredParam(this.name, this.type);
}

class OscQueryException implements Exception {
  final String message;
  OscQueryException(this.message);
  @override
  String toString() => message;
}

/// finds a running VRChat instance via mDNS (OSCQuery) and reads its live
/// /avatar/parameters tree, so parameter names don't have to be typed by hand.
class OscQueryClient {
  /// finds OSCQuery services named "VRChat" (or, with [anyOscQueryService],
  /// any of them). [error] is only set when the search itself broke (mDNS
  /// start failure etc.), not when it just found nothing.
  ///
  /// a fresh client each attempt - Windows lets multiple processes bind UDP
  /// 5353 at once but doesn't always fan out a reply to all of them, so a
  /// fresh bind plus a jittered retry gap raises the odds of winning that race.
  static Future<({List<(String host, int port)> instances, String? error})> findVrchatInstances({
    Duration timeout = const Duration(seconds: 4),
    bool anyOscQueryService = false,
    int maxAttempts = 3,
  }) async {
    Object? lastError;
    for (var attempt = 0; attempt < maxAttempts; attempt++) {
      if (attempt > 0) {
        await Future.delayed(Duration(milliseconds: 250 + Random().nextInt(300)));
      }
      final (results, error) = await _attemptFind(timeout, anyOscQueryService);
      if (results != null && results.isNotEmpty) return (instances: results, error: null);
      if (results != null) continue; // clean empty result - still worth another roll of the dice
      lastError = error;
    }
    return (instances: const <(String, int)>[], error: lastError?.toString());
  }

  static Future<(List<(String host, int port)>?, Object?)> _attemptFind(
    Duration timeout,
    bool anyOscQueryService,
  ) async {
    final client = MDnsClient(rawDatagramSocketFactory: _bindWithoutReusePort);
    final results = <(String host, int port)>[];
    try {
      await client.start(interfacesFactory: _joinableInterfacesFactory);
    } catch (e) {
      try {
        client.stop();
      } catch (_) {}
      return (null, e);
    }

    try {
      await for (final ptr in client
          .lookup<PtrResourceRecord>(
            ResourceRecordQuery.serverPointer(_oscJsonServiceType),
          )
          .timeout(timeout, onTimeout: (sink) => sink.close())) {
        if (!anyOscQueryService && !ptr.domainName.toLowerCase().contains('vrchat')) continue;

        await for (final srv in client
            .lookup<SrvResourceRecord>(
              ResourceRecordQuery.service(ptr.domainName),
            )
            .timeout(const Duration(seconds: 2), onTimeout: (sink) => sink.close())) {
          await for (final ip in client
              .lookup<IPAddressResourceRecord>(
                ResourceRecordQuery.addressIPv4(srv.target),
              )
              .timeout(const Duration(seconds: 2), onTimeout: (sink) => sink.close())) {
            results.add((ip.address.address, srv.port));
          }
        }
      }
    } catch (e) {
      return (null, e);
    } finally {
      client.stop();
    }
    return (results.toSet().toList(), null);
  }

  /// queries the OSCQuery HTTP JSON tree at /avatar/parameters and returns
  /// every leaf parameter found, typed as slider (float/int) or toggle (bool).
  ///
  /// this has been observed to hang outright (not just respond slowly) on
  /// some avatars - intermittently, since a fresh request sometimes succeeds
  /// where a previous one hung. treat a thrown exception as "couldn't get the
  /// authoritative list," not fatal - callers should fall back to something
  /// else (e.g. live OSC listening).
  static Future<List<DiscoveredParam>> fetchAvatarParameters(
    String host,
    int port, {
    int maxAttempts = 2,
    Duration perAttemptTimeout = const Duration(seconds: 5),
  }) async {
    Object? lastError;
    for (var attempt = 0; attempt < maxAttempts; attempt++) {
      try {
        return await _attemptFetchAvatarParameters(host, port, perAttemptTimeout);
      } catch (e) {
        lastError = e;
      }
    }
    throw lastError!;
  }

  static Future<List<DiscoveredParam>> _attemptFetchAvatarParameters(
    String host,
    int port,
    Duration timeout,
  ) async {
    final httpClient = HttpClient();
    try {
      final uri = Uri.parse('http://$host:$port/avatar/parameters');
      return await _doFetchAvatarParameters(httpClient, uri).timeout(
        timeout,
        onTimeout: () => throw OscQueryException('Timed out waiting for a response to $uri.'),
      );
    } finally {
      httpClient.close(force: true);
    }
  }

  static Future<List<DiscoveredParam>> _doFetchAvatarParameters(HttpClient httpClient, Uri uri) async {
    final request = await httpClient.getUrl(uri);
    // rules out a keep-alive/connection-reuse quirk, cheap insurance even
    // though the observed hang traces to the server itself.
    request.persistentConnection = false;
    final response = await request.close();
    if (response.statusCode != 200) {
      throw OscQueryException('OSCQuery HTTP ${response.statusCode} from $uri');
    }
    final body = await response.transform(utf8.decoder).join();
    final json = jsonDecode(body) as Map<String, dynamic>;

    final byName = <String, DiscoveredParam>{};
    _walk(json, byName);
    return byName.values.toList();
  }

  /// fetches one parameter's live value (not the whole tree). returns null
  /// only for "found it but it's not a bool/float" - anything else throws,
  /// so the caller can show what actually went wrong.
  static Future<Object?> fetchParameterValue(
    String host,
    int port,
    String paramName, {
    Duration timeout = const Duration(seconds: 5),
  }) async {
    final httpClient = HttpClient();
    try {
      final uri = Uri(scheme: 'http', host: host, port: port, path: '$_paramsRoot$paramName');
      return await _doFetchParameterValue(httpClient, uri, paramName).timeout(timeout);
    } finally {
      httpClient.close(force: true);
    }
  }

  static Future<Object?> _doFetchParameterValue(HttpClient httpClient, Uri uri, String paramName) async {
    final request = await httpClient.getUrl(uri);
    final response = await request.close();
    if (response.statusCode != 200) {
      throw OscQueryException('OSCQuery HTTP ${response.statusCode} for "$paramName"');
    }
    final body = await response.transform(utf8.decoder).join();
    final json = jsonDecode(body) as Map<String, dynamic>;

    final typeTag = json['TYPE'] as String?;
    // bool params report their value as the TYPE tag itself ('T'/'F'),
    // since OSC has no separate bool type independent of the value.
    if (typeTag == 'T') return true;
    if (typeTag == 'F') return false;
    final rawValue = json['VALUE'];
    if (rawValue is List && rawValue.isNotEmpty && rawValue.first is num) {
      return (rawValue.first as num).toDouble();
    }
    return null;
  }

  static const _paramsRoot = '/avatar/parameters/';

  static void _walk(Map<String, dynamic> node, Map<String, DiscoveredParam> out) {
    final contents = node['CONTENTS'] as Map<String, dynamic>?;
    if (contents == null) {
      // leaf node - has a TYPE and a FULL_PATH.
      final fullPath = node['FULL_PATH'] as String?;
      final typeTag = node['TYPE'] as String?;
      if (fullPath == null || typeTag == null) return;
      // VRChat's own per-avatar OSC config confirms these nested paths (e.g.
      // "/avatar/parameters/VF67_Mayu/Purr") ARE the real addressable OSC
      // address, not just organizational grouping - keep everything after
      // the /avatar/parameters/ root verbatim, slashes included.
      final name = fullPath.startsWith(_paramsRoot) ? fullPath.substring(_paramsRoot.length) : fullPath;
      // bool params report their current value's tag ('T' or 'F') as TYPE,
      // since OSC has no separate "bool type" independent of the value.
      final isBool = typeTag == 'T' || typeTag == 'F';
      out[name] = DiscoveredParam(name, isBool ? ParamType.toggle : ParamType.slider);
      return;
    }
    for (final child in contents.values) {
      _walk(child as Map<String, dynamic>, out);
    }
  }
}
