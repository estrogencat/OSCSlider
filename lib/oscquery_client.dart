import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:multicast_dns/multicast_dns.dart';

import 'osc_input_hub.dart';
import 'oscquery_service.dart';
import 'param_control.dart';

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

/// how a parameter is typed on the avatar, as far as discovery can tell.
enum DiscoveredKind { bool, int, float }

class DiscoveredParam {
  final String name;
  final DiscoveredKind kind;
  // VRChat's built-ins (IsLocal, Grounded, VelocityX, ...) are output-only -
  // sending to them does nothing.
  final bool readOnly;
  // the live value when the source reported one.
  final Object? value;

  const DiscoveredParam(this.name, this.kind, {this.readOnly = false, this.value});

  ParamType get type => kind == DiscoveredKind.bool ? ParamType.toggle : ParamType.slider;

  /// a ready-to-add control, typed and ranged to match VRChat's own
  /// conventions (ints are 0-255, floats 0-1 by default).
  ParamControl toControl() {
    final control = ParamControl(name: name, label: name.split('/').last, type: type);
    if (kind == DiscoveredKind.int) {
      control
        ..numericKind = NumericKind.int
        ..min = 0
        ..max = 255;
    }
    return control;
  }
}

class OscQueryException implements Exception {
  final String message;
  final bool notFound;
  OscQueryException(this.message, {this.notFound = false});
  @override
  String toString() => message;
}

/// one OSCQuery HTTP endpoint that answered.
class OscQueryEndpoint {
  final String name;
  final String host;
  final int port;
  // where that service takes OSC input, from its HOST_INFO.
  final String? oscHost;
  final int? oscPort;
  const OscQueryEndpoint(this.name, this.host, this.port, {this.oscHost, this.oscPort});
}

/// VRChat's outgoing-only built-in parameters - used to flag them when the
/// list came from live traffic rather than OSCQuery (which reports ACCESS).
const vrchatReadOnlyBuiltins = {
  'IsLocal', 'Viseme', 'Voice', 'GestureLeft', 'GestureRight', 'GestureLeftWeight', 'GestureRightWeight',
  'AngularY', 'VelocityX', 'VelocityY', 'VelocityZ', 'VelocityMagnitude', 'Upright', 'Grounded', 'Seated',
  'AFK', 'TrackingType', 'VRMode', 'MuteSelf', 'InStation', 'Earmuffs', 'IsOnFriendsList', 'AvatarVersion',
  'IsAnimatorEnabled', 'ScaleModified', 'ScaleFactor', 'ScaleFactorInverse', 'EyeHeightAsMeters',
  'EyeHeightAsPercent', 'PreviewMode',
};

/// finds a running VRChat instance via mDNS (OSCQuery) and reads its live
/// /avatar/parameters tree, so parameter names don't have to be typed by hand.
class OscQueryClient {
  static OscQueryEndpoint? _lastGood;

  /// finds OSCQuery services named "VRChat" (or, with [anyOscQueryService],
  /// any of them other than OSCSlider itself). each candidate is confirmed
  /// alive over HTTP before being returned, so a stale mDNS record or a
  /// VRChat on another PC in the house can't be picked by mistake. [error]
  /// is only set when the search itself broke, not when it found nothing.
  ///
  /// tries, fastest first: the last endpoint that worked, services this
  /// app's own OSCQuery listener already heard about passively, and only
  /// then a fresh mDNS search (a new client each attempt - Windows lets
  /// multiple processes bind UDP 5353 but doesn't always fan a reply out to
  /// all of them, so a fresh bind plus a jittered retry raises the odds).
  static Future<({OscQueryEndpoint? endpoint, String? error})> findVrchat({
    Duration timeout = const Duration(seconds: 4),
    bool anyOscQueryService = false,
    int maxAttempts = 2,
  }) async {
    bool wanted(String name) {
      final lower = name.toLowerCase();
      if (lower.startsWith('oscslider-')) return false;
      return anyOscQueryService || lower.contains('vrchat');
    }

    final cached = _lastGood;
    if (cached != null && wanted(cached.name)) {
      final ok = await _verify(cached.name, cached.host, cached.port);
      if (ok != null) return (endpoint: ok, error: null);
      _lastGood = null;
    }

    final service = oscInputHub.service;
    if (service != null) {
      Future<OscQueryEndpoint?> tryKnown() async {
        final known = service.peers.where((p) => wanted(p.instanceName)).toList()..sort(_localFirst);
        for (final peer in known) {
          final ok = await _verify(peer.instanceName, peer.host, peer.port);
          if (ok != null) return ok;
          service.forgetPeer(peer);
        }
        return null;
      }

      var found = await tryKnown();
      if (found == null && service.isAdvertising) {
        // ask once on the shared socket and give answers a moment to land -
        // VRChat replies within milliseconds when it's there.
        service.queryPeers();
        for (var i = 0; i < 8 && found == null; i++) {
          await Future.delayed(const Duration(milliseconds: 200));
          if (service.peers.any((p) => wanted(p.instanceName))) found = await tryKnown();
        }
      }
      if (found != null) return (endpoint: _lastGood = found, error: null);
      // this app's own listener would have heard a reply already, so one
      // fresh-socket search is plenty as a second opinion.
      if (service.isAdvertising) maxAttempts = 1;
    }

    Object? lastError;
    for (var attempt = 0; attempt < maxAttempts; attempt++) {
      if (attempt > 0) {
        await Future.delayed(Duration(milliseconds: 250 + Random().nextInt(300)));
      }
      final (found, error) = await _attemptFind(timeout, wanted);
      if (found != null) return (endpoint: _lastGood = found, error: null);
      if (error != null) lastError = error;
      // a clean empty result is still worth another roll of the dice.
    }
    return (endpoint: null, error: lastError?.toString());
  }

  static int _localFirst(OscQueryPeer a, OscQueryPeer b) {
    int rank(OscQueryPeer p) => p.host.startsWith('127.') ? 0 : 1;
    return rank(a) - rank(b);
  }

  static Future<(OscQueryEndpoint?, Object?)> _attemptFind(Duration timeout, bool Function(String) wanted) async {
    final client = MDnsClient(rawDatagramSocketFactory: _bindWithoutReusePort);
    try {
      await client.start(interfacesFactory: _joinableInterfacesFactory);
    } catch (e) {
      try {
        client.stop();
      } catch (_) {}
      return (null, e);
    }

    try {
      final candidates = <(String, String, int)>[];
      // breaks out as soon as something usable turns up, instead of always
      // sitting through every lookup's full timeout.
      await for (final ptr in client
          .lookup<PtrResourceRecord>(ResourceRecordQuery.serverPointer(oscJsonServiceType))
          .timeout(timeout, onTimeout: (sink) => sink.close())) {
        final instance = ptr.domainName.split('.').first;
        if (!wanted(instance)) continue;
        await for (final srv in client
            .lookup<SrvResourceRecord>(ResourceRecordQuery.service(ptr.domainName))
            .timeout(const Duration(seconds: 2), onTimeout: (sink) => sink.close())) {
          await for (final ip in client
              .lookup<IPAddressResourceRecord>(ResourceRecordQuery.addressIPv4(srv.target))
              .timeout(const Duration(seconds: 2), onTimeout: (sink) => sink.close())) {
            candidates.add((instance, ip.address.address, srv.port));
            break;
          }
          break;
        }
        candidates.sort((a, b) => (a.$2.startsWith('127.') ? 0 : 1) - (b.$2.startsWith('127.') ? 0 : 1));
        for (final (name, host, port) in candidates) {
          final ok = await _verify(name, host, port);
          if (ok != null) return (ok, null);
        }
        candidates.clear();
      }
    } catch (e) {
      return (null, e);
    } finally {
      client.stop();
    }
    return (null, null);
  }

  /// null unless [host]:[port] answers a HOST_INFO request - cheap, and
  /// unlike the full tree it doesn't hang on heavy avatars.
  static Future<OscQueryEndpoint?> _verify(String name, String host, int port) async {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 2);
    try {
      final request = await client.getUrl(Uri(scheme: 'http', host: host, port: port, path: '/', query: 'HOST_INFO'));
      request.persistentConnection = false;
      final response = await request.close().timeout(const Duration(seconds: 3));
      if (response.statusCode != 200) return null;
      final body = await response.transform(utf8.decoder).join().timeout(const Duration(seconds: 3));
      final json = jsonDecode(body);
      if (json is! Map) return OscQueryEndpoint(name, host, port);
      return OscQueryEndpoint(
        name,
        host,
        port,
        oscHost: json['OSC_IP'] as String?,
        oscPort: (json['OSC_PORT'] as num?)?.toInt(),
      );
    } catch (_) {
      return null;
    } finally {
      client.close(force: true);
    }
  }

  /// queries the OSCQuery HTTP JSON tree at /avatar/parameters and returns
  /// every leaf parameter found, typed and with its live value.
  ///
  /// this has been observed to hang outright (not just respond slowly) on
  /// some avatars - intermittently, since a fresh request sometimes succeeds
  /// where a previous one hung. treat a thrown exception as "couldn't get the
  /// authoritative list," not fatal - callers should fall back to something
  /// else (VRChat's saved avatar config, or live OSC listening).
  static Future<List<DiscoveredParam>> fetchAvatarParameters(
    OscQueryEndpoint endpoint, {
    int maxAttempts = 2,
    Duration perAttemptTimeout = const Duration(seconds: 5),
  }) async {
    Object? lastError;
    for (var attempt = 0; attempt < maxAttempts; attempt++) {
      try {
        final json = await _getJson(endpoint, '/avatar/parameters', perAttemptTimeout);
        final byName = <String, DiscoveredParam>{};
        _walk(json, byName);
        return byName.values.toList()..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
      } catch (e) {
        lastError = e;
        if (e is OscQueryException && e.notFound) break;
      }
    }
    throw lastError!;
  }

  /// the current avatar's id, from VRChat's /avatar/change node - a tiny
  /// request that still works when the full parameter tree hangs.
  static Future<String?> fetchAvatarId(OscQueryEndpoint endpoint, {Duration timeout = const Duration(seconds: 3)}) async {
    try {
      final json = await _getJson(endpoint, '/avatar/change', timeout);
      final value = json['VALUE'];
      if (value is List && value.isNotEmpty && value.first is String) return value.first as String;
    } catch (_) {}
    return null;
  }

  /// fetches one parameter's live value (not the whole tree) at the full
  /// OSC [address]. bool for toggles, double for numbers; null only for "found
  /// it but it's some other type" - anything else throws, so the caller can
  /// show what actually went wrong.
  static Future<Object?> fetchParameterValue(
    OscQueryEndpoint endpoint,
    String address, {
    Duration timeout = const Duration(seconds: 5),
  }) async {
    final json = await _getJson(endpoint, address, timeout);
    return valueFromNode(json);
  }

  /// VRChat reports every bool with TYPE "T" and the real state in VALUE -
  /// so VALUE decides, and TYPE only matters when there's no VALUE at all.
  static Object? valueFromNode(Map<String, dynamic> json) {
    final typeTag = json['TYPE'] as String?;
    final rawValue = json['VALUE'];
    final first = rawValue is List && rawValue.isNotEmpty ? rawValue.first : null;
    if (first is bool) return first;
    if (first is num) return typeTag == 'T' || typeTag == 'F' ? first != 0 : first.toDouble();
    if (typeTag == 'T') return true;
    if (typeTag == 'F') return false;
    return null;
  }

  static Future<Map<String, dynamic>> _getJson(OscQueryEndpoint endpoint, String path, Duration timeout) async {
    final httpClient = HttpClient()..connectionTimeout = timeout;
    final uri = Uri(scheme: 'http', host: endpoint.host, port: endpoint.port, path: path);
    try {
      return await () async {
        final request = await httpClient.getUrl(uri);
        // rules out a keep-alive/connection-reuse quirk, cheap insurance even
        // though the observed hang traces to the server itself.
        request.persistentConnection = false;
        final response = await request.close();
        if (response.statusCode == 404) {
          await response.drain<void>();
          throw OscQueryException('Not found: $path', notFound: true);
        }
        if (response.statusCode != 200) {
          await response.drain<void>();
          throw OscQueryException('OSCQuery HTTP ${response.statusCode} from $uri');
        }
        final body = await response.transform(utf8.decoder).join();
        final json = jsonDecode(body);
        if (json is! Map<String, dynamic>) throw OscQueryException('Unexpected response from $uri');
        return json;
      }()
          .timeout(timeout, onTimeout: () => throw OscQueryException('Timed out waiting for a response to $uri.'));
    } on SocketException catch (e) {
      throw OscQueryException('Could not connect to $uri: ${e.message}');
    } finally {
      httpClient.close(force: true);
    }
  }

  static const _paramsRoot = '/avatar/parameters/';

  static void _walk(Map<String, dynamic> node, Map<String, DiscoveredParam> out) {
    final contents = node['CONTENTS'];
    if (contents is Map<String, dynamic> && contents.isNotEmpty) {
      for (final child in contents.values) {
        if (child is Map<String, dynamic>) _walk(child, out);
      }
      return;
    }
    // leaf node - has a TYPE and a FULL_PATH.
    final fullPath = node['FULL_PATH'] as String?;
    final typeTag = node['TYPE'] as String?;
    if (fullPath == null || typeTag == null) return;
    // VRChat's own per-avatar OSC config confirms these nested paths (e.g.
    // "/avatar/parameters/VF67_Mayu/Purr") ARE the real addressable OSC
    // address, not just organizational grouping - keep everything after
    // the /avatar/parameters/ root verbatim, slashes included.
    final name = fullPath.startsWith(_paramsRoot) ? fullPath.substring(_paramsRoot.length) : fullPath;
    final kind = switch (typeTag) {
      'T' || 'F' => DiscoveredKind.bool,
      'i' => DiscoveredKind.int,
      'f' || 'd' => DiscoveredKind.float,
      _ => null,
    };
    if (kind == null) return;
    // ACCESS 1 = read-only (VRChat's built-ins); 2/3 accept input.
    final access = (node['ACCESS'] as num?)?.toInt();
    out[name] = DiscoveredParam(name, kind, readOnly: access == 1, value: valueFromNode(node));
  }
}
