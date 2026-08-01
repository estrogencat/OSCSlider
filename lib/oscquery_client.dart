import 'dart:convert';
import 'dart:io';

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
Future<Iterable<NetworkInterface>> _joinableInterfacesFactory(InternetAddressType type) async {
  final all = await NetworkInterface.list(includeLinkLocal: true, type: type);
  final usable = <NetworkInterface>[];
  final mdnsAddress = type == InternetAddressType.IPv6 ? _mdnsAddressIPv6 : _mdnsAddressIPv4;
  for (final iface in all) {
    if (iface.addresses.isEmpty) continue;
    RawDatagramSocket? probe;
    try {
      probe = await RawDatagramSocket.bind(
        type == InternetAddressType.IPv6 ? InternetAddress.anyIPv6 : InternetAddress.anyIPv4,
        0,
      );
      probe.joinMulticast(mdnsAddress, iface);
      usable.add(iface);
    } catch (_) {
      // interface doesn't support multicast - skip it.
    } finally {
      probe?.close();
    }
  }
  return usable;
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
  /// returns host:port of every OSCQuery service found advertising itself
  /// with a name starting with "VRChat" (there's usually exactly one).
  static Future<List<(String host, int port)>> findVrchatInstances({
    Duration timeout = const Duration(seconds: 4),
  }) async {
    final client = MDnsClient(rawDatagramSocketFactory: _bindWithoutReusePort);
    final results = <(String host, int port)>[];
    try {
      await client.start(interfacesFactory: _joinableInterfacesFactory);

      await for (final ptr in client
          .lookup<PtrResourceRecord>(
            ResourceRecordQuery.serverPointer(_oscJsonServiceType),
          )
          .timeout(timeout, onTimeout: (sink) => sink.close())) {
        if (!ptr.domainName.toLowerCase().contains('vrchat')) continue;

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
    } finally {
      client.stop();
    }
    return results.toSet().toList();
  }

  /// queries the OSCQuery HTTP JSON tree at /avatar/parameters and returns
  /// every leaf parameter found, typed as slider (float/int) or toggle (bool).
  static Future<List<DiscoveredParam>> fetchAvatarParameters(String host, int port) async {
    final httpClient = HttpClient();
    try {
      final uri = Uri.parse('http://$host:$port/avatar/parameters');
      final request = await httpClient.getUrl(uri).timeout(const Duration(seconds: 5));
      final response = await request.close().timeout(const Duration(seconds: 5));
      if (response.statusCode != 200) {
        throw OscQueryException('OSCQuery HTTP ${response.statusCode} from $uri');
      }
      final body = await response.transform(utf8.decoder).join();
      final json = jsonDecode(body) as Map<String, dynamic>;

      final byName = <String, DiscoveredParam>{};
      _walk(json, byName);
      return byName.values.toList();
    } finally {
      httpClient.close(force: true);
    }
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
