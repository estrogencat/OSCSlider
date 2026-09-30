import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';

import 'crash_log.dart';
import 'mdns_codec.dart';

const oscJsonServiceType = '_oscjson._tcp.local';
const oscUdpServiceType = '_osc._udp.local';
const _dnsSdServicesType = '_services._dns-sd._udp.local';
const mdnsPort = 5353;
final mdnsGroupIPv4 = InternetAddress('224.0.0.251');

/// another OSCQuery service seen on the network (VRChat, or any other app).
class OscQueryPeer {
  final String instanceName;
  final String host;
  final int port;
  final DateTime lastSeen;
  const OscQueryPeer(this.instanceName, this.host, this.port, this.lastSeen);

  bool get isVrchat => instanceName.toLowerCase().startsWith('vrchat-client');
}

class _Advertised {
  final String type;
  final String fqdn;
  final String host;
  final int port;
  _Advertised(this.type, String instance, String hostSuffix, this.port)
      : fqdn = '$instance.$type',
        host = '$instance.$hostSuffix.local';
}

/// this app's own OSCQuery service - the same thing VRCFaceTracking, VRCOSC
/// and friends do so several apps can all receive VRChat's output at once:
/// advertise an OSC port over mDNS, and VRChat sends its parameter traffic
/// there directly instead of everyone fighting over UDP 9001.
///
/// also passively notes every other OSCQuery service it hears about
/// (VRChat's own included), which makes finding VRChat near-instant.
class OscQueryService {
  final void Function(Uint8List data) onPacket;
  late final String instanceName = 'OSCSlider-${_randomId(6)}';

  RawDatagramSocket? _osc;
  HttpServer? _http;
  RawDatagramSocket? _mdns;
  final List<InternetAddress> _multicastInterfaces = [];
  final List<Timer> _timers = [];
  final Map<String, OscQueryPeer> _peers = {};
  bool _stopped = false;

  /// bumped whenever [peers] changes.
  final ValueNotifier<int> peersRevision = ValueNotifier(0);

  /// why advertising isn't fully working, if it isn't (shown in Settings).
  String? error;

  OscQueryService({required this.onPacket});

  int? get oscPort => _osc?.port;
  int? get httpPort => _http?.port;
  bool get isAdvertising => _mdns != null && _http != null && _osc != null;
  List<OscQueryPeer> get peers => _peers.values.toList();

  static String _randomId(int length) {
    const chars = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
    final rand = Random();
    return List.generate(length, (_) => chars[rand.nextInt(chars.length)]).join();
  }

  List<_Advertised> get _services => [
        if (_http != null) _Advertised(oscJsonServiceType, instanceName, 'oscjson', _http!.port),
        if (_osc != null) _Advertised(oscUdpServiceType, instanceName, 'osc', _osc!.port),
      ];

  Future<void> start() async {
    final problems = <String>[];
    try {
      // loopback only - VRChat on this PC is the audience, and a loopback
      // bind doesn't trip a Windows Firewall prompt.
      final osc = await RawDatagramSocket.bind(InternetAddress.loopbackIPv4, 0);
      osc.listen((event) {
        if (event != RawSocketEvent.read) return;
        final dg = osc.receive();
        if (dg != null) onPacket(dg.data);
      }, onError: (Object e, StackTrace st) => CrashLog.record(e, st, context: 'OSCQuery OSC socket'));
      _osc = osc;
    } catch (e) {
      problems.add('OSC receive socket: $e');
    }

    try {
      final http = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      http.listen(_handleHttp, onError: (Object e, StackTrace st) => CrashLog.record(e, st, context: 'OSCQuery HTTP'));
      _http = http;
    } catch (e) {
      problems.add('HTTP server: $e');
    }

    try {
      await _startMdns();
    } catch (e) {
      problems.add('mDNS (UDP 5353): $e');
    }
    error = problems.isEmpty ? null : problems.join('\n');
    if (_stopped) {
      await stop();
      return;
    }

    if (_mdns != null) {
      // RFC 6762 announces a couple of times, spaced out, so a listener that
      // missed the first one still hears about us.
      _announce();
      _timers.add(Timer(const Duration(seconds: 1), _announce));
      _timers.add(Timer(const Duration(seconds: 3), _announce));
      queryPeers();
    }
  }

  Future<void> _startMdns() async {
    // shared with every other mDNS user on this machine (VRChat included) -
    // reusePort isn't supported on Windows, reuseAddress is what lets it share.
    final socket = await RawDatagramSocket.bind(
      InternetAddress.anyIPv4,
      mdnsPort,
      reuseAddress: true,
      reusePort: false,
      ttl: 255,
    );
    socket.multicastLoopback = true;
    final interfaces = await NetworkInterface.list(includeLoopback: true, type: InternetAddressType.IPv4);
    for (final iface in interfaces) {
      try {
        socket.joinMulticast(mdnsGroupIPv4, iface);
        _multicastInterfaces.addAll(iface.addresses.where((a) => a.type == InternetAddressType.IPv4));
      } catch (_) {
        // virtual adapters (VPNs, Hyper-V) often refuse multicast - skip them.
      }
    }
    if (_multicastInterfaces.isEmpty) {
      socket.joinMulticast(mdnsGroupIPv4);
    }
    socket.listen((event) {
      if (event != RawSocketEvent.read) return;
      final dg = socket.receive();
      if (dg == null) return;
      try {
        _handleMdns(dg);
      } catch (e, st) {
        CrashLog.record(e, st, context: 'OSCQuery mDNS packet');
      }
    }, onError: (Object e, StackTrace st) => CrashLog.record(e, st, context: 'OSCQuery mDNS socket'));
    _mdns = socket;
  }

  Future<void> stop() async {
    _stopped = true;
    for (final t in _timers) {
      t.cancel();
    }
    _timers.clear();
    if (_mdns != null) {
      // a zero TTL tells VRChat to forget this service right away instead of
      // sending into a closed port until its cache entry expires.
      _sendMulticast(encodeDnsMessage(DnsMessage(
        isResponse: true,
        answers: [for (final r in _allRecords()) r.withTtl(0)],
      )));
    }
    _mdns?.close();
    _mdns = null;
    _osc?.close();
    _osc = null;
    await _http?.close(force: true);
    _http = null;
  }

  /// asks the network for OSCQuery services - answers land in [peers].
  void queryPeers() {
    if (_mdns == null) return;
    _sendMulticast(encodeDnsMessage(const DnsMessage(
      isResponse: false,
      questions: [DnsQuestion(oscJsonServiceType, DnsType.ptr)],
    )));
  }

  void forgetPeer(OscQueryPeer peer) {
    _peers.removeWhere((_, p) => p.host == peer.host && p.port == peer.port);
    peersRevision.value++;
  }

  List<DnsRecord> _recordsFor(_Advertised svc) => [
        DnsRecord.ptr(svc.type, svc.fqdn),
        DnsRecord.srv(svc.fqdn, svc.host, svc.port),
        DnsRecord.txt(svc.fqdn, const ['txtvers=1']),
        DnsRecord.a(svc.host, InternetAddress.loopbackIPv4),
      ];

  List<DnsRecord> _allRecords() => [for (final s in _services) ..._recordsFor(s)];

  void _announce() {
    if (_mdns == null || _stopped) return;
    final services = _services;
    if (services.isEmpty) return;
    _sendMulticast(encodeDnsMessage(DnsMessage(
      isResponse: true,
      answers: [for (final s in services) DnsRecord.ptr(s.type, s.fqdn)],
      additionals: [for (final s in services) ..._recordsFor(s).skip(1)],
    )));
  }

  void _sendMulticast(Uint8List bytes) {
    final socket = _mdns;
    if (socket == null) return;
    var sentAny = false;
    // once on the default route (what VRChat's own mDNS stack hears on a
    // normal PC), then out every other multicast-capable interface too.
    try {
      socket.send(bytes, mdnsGroupIPv4, mdnsPort);
      sentAny = true;
    } catch (_) {}
    for (final addr in _multicastInterfaces) {
      try {
        socket.setRawOption(RawSocketOption(
          RawSocketOption.levelIPv4,
          RawSocketOption.IPv4MulticastInterface,
          addr.rawAddress,
        ));
        socket.send(bytes, mdnsGroupIPv4, mdnsPort);
        sentAny = true;
      } catch (_) {}
    }
    if (!sentAny) error ??= 'Could not send mDNS packets on any network interface.';
  }

  void _handleMdns(Datagram dg) {
    final msg = decodeDnsMessage(dg.data);
    if (msg == null) return;
    if (msg.isResponse) {
      _learn(msg, dg.address);
    } else {
      _answer(msg, dg);
    }
  }

  void _answer(DnsMessage query, Datagram dg) {
    final answers = <DnsRecord>[];
    final additionals = <DnsRecord>[];
    final services = _services;
    var wantsUnicast = false;
    for (final q in query.questions) {
      wantsUnicast |= q.unicastResponse;
      final any = q.type == DnsType.any;
      for (final svc in services) {
        final records = _recordsFor(svc);
        if (dnsNamesEqual(q.name, svc.type) && (any || q.type == DnsType.ptr)) {
          answers.add(records[0]);
          additionals.addAll(records.skip(1));
        } else if (dnsNamesEqual(q.name, svc.fqdn)) {
          if (any || q.type == DnsType.srv) answers.add(records[1]);
          if (any || q.type == DnsType.txt) answers.add(records[2]);
          additionals.add(records[3]);
        } else if (dnsNamesEqual(q.name, svc.host) && (any || q.type == DnsType.a)) {
          answers.add(records[3]);
        }
      }
      if (dnsNamesEqual(q.name, _dnsSdServicesType) && (any || q.type == DnsType.ptr)) {
        for (final svc in services) {
          answers.add(DnsRecord.ptr(_dnsSdServicesType, svc.type));
        }
      }
    }
    if (answers.isEmpty) return;
    additionals.removeWhere((a) => answers.any((b) => b.type == a.type && dnsNamesEqual(b.name, a.name)));

    final socket = _mdns;
    if (socket == null) return;
    if (dg.port != mdnsPort) {
      // a "legacy unicast" one-shot query (not from an mDNS stack) - reply
      // straight back to it, echoing its id/questions, with short TTLs.
      final reply = DnsMessage(
        id: query.id,
        isResponse: true,
        questions: query.questions,
        answers: [for (final r in answers) r.withTtl(min(r.ttl, 10))],
        additionals: [for (final r in additionals) r.withTtl(min(r.ttl, 10))],
      );
      try {
        socket.send(encodeDnsMessage(reply), dg.address, dg.port);
      } catch (_) {}
      return;
    }
    final bytes = encodeDnsMessage(DnsMessage(isResponse: true, answers: answers, additionals: additionals));
    if (wantsUnicast) {
      try {
        socket.send(bytes, dg.address, mdnsPort);
      } catch (_) {}
    }
    _sendMulticast(bytes);
  }

  void _learn(DnsMessage msg, InternetAddress from) {
    final records = msg.allRecords.toList();
    var changed = false;
    for (final ptr in records.where((r) => r.type == DnsType.ptr && dnsNamesEqual(r.name, oscJsonServiceType))) {
      final target = ptr.ptrTarget;
      if (target == null) continue;
      final instance = target.split('.').first;
      if (instance == instanceName) continue;
      final key = target.toLowerCase();
      if (ptr.ttl == 0) {
        changed |= _peers.remove(key) != null;
        continue;
      }
      final srv = records.where((r) => r.type == DnsType.srv && dnsNamesEqual(r.name, target)).firstOrNull;
      if (srv == null || srv.srvPort == null) continue;
      if (srv.ttl == 0) {
        changed |= _peers.remove(key) != null;
        continue;
      }
      final a = records
          .where((r) => r.type == DnsType.a && srv.srvTarget != null && dnsNamesEqual(r.name, srv.srvTarget!))
          .firstOrNull;
      final host = a?.address?.address ?? from.address;
      _peers[key] = OscQueryPeer(instance, host, srv.srvPort!, DateTime.now());
      changed = true;
    }
    // a bare SRV goodbye (no PTR alongside it).
    for (final srv in records.where((r) => r.type == DnsType.srv && r.ttl == 0)) {
      changed |= _peers.remove(srv.name.toLowerCase()) != null;
    }
    if (changed) peersRevision.value++;
  }

  Future<void> _handleHttp(HttpRequest request) async {
    final response = request.response;
    try {
      response.headers.set('Cache-Control', 'no-cache');
      if (request.uri.query.contains('HOST_INFO')) {
        _json(response, _hostInfo());
      } else {
        final node = _nodeAt(request.uri.path);
        if (node == null) {
          response.statusCode = HttpStatus.notFound;
          response.write('OSC Path not found');
        } else {
          _json(response, node);
        }
      }
    } catch (e, st) {
      CrashLog.record(e, st, context: 'OSCQuery HTTP request');
      response.statusCode = HttpStatus.internalServerError;
    } finally {
      try {
        await response.close();
      } catch (_) {}
    }
  }

  void _json(HttpResponse response, Map<String, Object?> body) {
    response.headers.contentType = ContentType.json;
    response.write(jsonEncode(body));
  }

  Map<String, Object?> _hostInfo() => {
        'NAME': instanceName,
        'OSC_IP': InternetAddress.loopbackIPv4.address,
        'OSC_PORT': _osc?.port ?? 0,
        'OSC_TRANSPORT': 'UDP',
        'EXTENSIONS': {
          'ACCESS': true,
          'CLIPMODE': false,
          'RANGE': false,
          'TYPE': true,
          'VALUE': false,
        },
      };

  // advertising /avatar/change (and the /avatar tree around it) is what
  // tells VRChat this app wants avatar data sent to it.
  Map<String, Object?> _tree() => {
        'DESCRIPTION': 'OSCSlider',
        'FULL_PATH': '/',
        'ACCESS': 0,
        'CONTENTS': {
          'avatar': {
            'FULL_PATH': '/avatar',
            'ACCESS': 2,
            'CONTENTS': {
              'change': {
                'DESCRIPTION': 'avatar id, sent by VRChat whenever the local avatar changes',
                'FULL_PATH': '/avatar/change',
                'ACCESS': 2,
                'TYPE': 's',
              },
              'parameters': {
                'FULL_PATH': '/avatar/parameters',
                'ACCESS': 2,
                'CONTENTS': <String, Object?>{},
              },
            },
          },
        },
      };

  Map<String, Object?>? _nodeAt(String path) {
    Map<String, Object?> node = _tree();
    for (final segment in path.split('/').where((s) => s.isNotEmpty)) {
      final contents = node['CONTENTS'];
      if (contents is! Map<String, Object?>) return null;
      final child = contents[segment];
      if (child is! Map<String, Object?>) return null;
      node = child;
    }
    return node;
  }
}
