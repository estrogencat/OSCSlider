import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import 'crash_log.dart';
import 'osc_listener.dart';
import 'oscquery_service.dart';

/// what the app currently knows about VRChat, for the status chip.
@immutable
class LinkStatus {
  /// OSC traffic arrived recently (from VRChat or anything else).
  final bool receiving;
  /// how that traffic is arriving - true for this app's own OSCQuery port,
  /// false for the legacy fixed listen port.
  final bool viaOscQuery;
  /// a VRChat OSCQuery service answered recently.
  final OscQueryPeer? vrchat;
  /// the port VRChat itself listens on, from its OSCQuery HOST_INFO.
  final int? vrchatInputPort;
  final String? vrchatInputHost;

  const LinkStatus({
    this.receiving = false,
    this.viaOscQuery = false,
    this.vrchat,
    this.vrchatInputPort,
    this.vrchatInputHost,
  });

  bool get vrchatFound => vrchat != null || receiving;
}

/// every incoming OSC message the app gets, from two possible sources:
///
/// 1. this app's own OSCQuery service ([OscQueryService]) - VRChat finds it
///    over mDNS and sends its output to a port only this app uses, so it
///    works alongside any number of other OSC apps.
/// 2. the classic fixed listen port (send port + 1, e.g. 9001), only while
///    something needs input and OSCQuery hasn't delivered anything yet -
///    for OSC software without OSCQuery. bound WITHOUT reuseAddress so it
///    can never steal another app's packets on Windows (where a shared
///    unicast port delivers to just one of the sockets); if the port is
///    taken it just stays off.
class OscInputHub {
  OscQueryService? _service;
  RawDatagramSocket? _legacy;
  int _legacyPort = 9001;
  int _refCount = 0;
  bool _oscQueryConfirmed = false;
  Future<void>? _legacyBinding;
  String? legacyError;
  /// the avatar VRChat most recently reported via /avatar/change.
  String? lastAvatarId;

  DateTime? _lastPacket;
  bool _lastPacketViaOscQuery = false;
  DateTime? _lastVerify;
  DateTime? _lastQuery;
  bool _verifying = false;
  Timer? _monitor;

  final _controller = StreamController<OscMessage>.broadcast();
  Stream<OscMessage> get messages => _controller.stream;

  @visibleForTesting
  void debugInject(OscMessage msg) => _controller.add(msg);

  final ValueNotifier<LinkStatus> status = ValueNotifier(const LinkStatus());

  OscQueryService? get service => _service;
  bool get legacyListening => _legacy != null;
  int get legacyPort => _legacyPort;

  /// starts the OSCQuery service - once, at app launch.
  Future<void> start({required int legacyPort}) async {
    _legacyPort = legacyPort;
    if (_service != null) return;
    final service = OscQueryService(onPacket: (data) => _onPacket(data, viaOscQuery: true));
    _service = service;
    service.peersRevision.addListener(_refreshStatus);
    await service.start();
    _monitor ??= Timer.periodic(const Duration(seconds: 3), (_) => _tickMonitor());
    _refreshStatus();
  }

  Future<void> stop() async {
    _monitor?.cancel();
    _monitor = null;
    _closeLegacy();
    await _service?.stop();
    _service = null;
  }

  /// a consumer that needs input (Auto Profile Mode, live highlighting,
  /// value sync) - call [release] when done. true if at least one input
  /// path is up.
  Future<bool> acquire() async {
    _refCount++;
    await _ensureLegacy();
    return isListening;
  }

  void release() {
    if (_refCount <= 0) return;
    _refCount--;
    if (_refCount == 0) _closeLegacy();
  }

  bool get isListening => (_service?.oscPort != null) || _legacy != null;

  /// the configured send port changed - follow it with the legacy listener.
  Future<void> setLegacyPort(int port) async {
    if (port == _legacyPort) return;
    _legacyPort = port;
    _closeLegacy();
    await _ensureLegacy();
  }

  Future<void> _ensureLegacy() {
    if (_refCount == 0 || _oscQueryConfirmed || _legacy != null) return Future.value();
    return _legacyBinding ??= _bindLegacy().whenComplete(() => _legacyBinding = null);
  }

  Future<void> _bindLegacy() async {
    final port = _legacyPort;
    try {
      final socket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, port, reuseAddress: false);
      if (_refCount == 0 || _oscQueryConfirmed || port != _legacyPort) {
        socket.close();
        return;
      }
      socket.listen(
        (event) {
          if (event == RawSocketEvent.closed) {
            if (identical(_legacy, socket)) _legacy = null;
            return;
          }
          if (event != RawSocketEvent.read) return;
          final dg = socket.receive();
          if (dg != null) _onPacket(dg.data, viaOscQuery: false);
        },
        onError: (Object e, StackTrace st) => CrashLog.record(e, st, context: 'legacy OSC port $port'),
      );
      _legacy = socket;
      legacyError = null;
    } catch (e) {
      // most likely another OSC app owns the port - that's fine, OSCQuery
      // covers VRChat without it.
      legacyError = 'Port $port is in use by another program.';
    }
  }

  void _closeLegacy() {
    _legacy?.close();
    _legacy = null;
  }

  void _onPacket(Uint8List data, {required bool viaOscQuery}) {
    if (viaOscQuery && !_oscQueryConfirmed) {
      // VRChat found us - the fixed port is no longer needed, so free it
      // for whatever else might want it (and avoid double delivery).
      _oscQueryConfirmed = true;
      _closeLegacy();
    }
    if (!viaOscQuery && _oscQueryConfirmed) return;
    final wasReceiving = status.value.receiving;
    _lastPacket = DateTime.now();
    _lastPacketViaOscQuery = viaOscQuery;
    for (final msg in parseOscPacket(data)) {
      if (msg.address == '/avatar/change' && msg.args.isNotEmpty && msg.args.first is String) {
        lastAvatarId = msg.args.first as String;
      }
      _controller.add(msg);
    }
    if (!wasReceiving) _refreshStatus();
  }

  OscQueryPeer? get _vrchatPeer {
    final peers = _service?.peers.where((p) => p.isVrchat).toList() ?? const [];
    if (peers.isEmpty) return null;
    // prefer one on this machine - mDNS is LAN-wide.
    peers.sort((a, b) => (_isLocal(b.host) ? 1 : 0) - (_isLocal(a.host) ? 1 : 0));
    return peers.first;
  }

  static bool _isLocal(String host) => host.startsWith('127.') || host == 'localhost';

  void _refreshStatus() {
    final receiving = _lastPacket != null && DateTime.now().difference(_lastPacket!) < const Duration(seconds: 12);
    final peer = _vrchatPeer;
    final current = status.value;
    final next = LinkStatus(
      receiving: receiving,
      viaOscQuery: receiving && _lastPacketViaOscQuery,
      vrchat: peer,
      vrchatInputPort: peer == null ? null : current.vrchatInputPort,
      vrchatInputHost: peer == null ? null : current.vrchatInputHost,
    );
    if (next.receiving != current.receiving ||
        next.viaOscQuery != current.viaOscQuery ||
        next.vrchat?.host != current.vrchat?.host ||
        next.vrchat?.port != current.vrchat?.port ||
        next.vrchatInputPort != current.vrchatInputPort) {
      status.value = next;
    }
  }

  void _tickMonitor() {
    _refreshStatus();
    final service = _service;
    if (service == null) return;
    final now = DateTime.now();
    final peer = _vrchatPeer;
    if (peer != null) {
      if (!_verifying && (_lastVerify == null || now.difference(_lastVerify!) > const Duration(seconds: 20))) {
        _verify(peer);
      }
    } else if (_lastQuery == null || now.difference(_lastQuery!) > const Duration(seconds: 60)) {
      // one tiny mDNS query a minute while VRChat isn't known - VRChat also
      // announces itself when it starts, so this is just a safety net.
      _lastQuery = now;
      service.queryPeers();
    }
  }

  /// confirms [peer] is still alive, reading which port it takes input on.
  Future<void> _verify(OscQueryPeer peer) async {
    _verifying = true;
    _lastVerify = DateTime.now();
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 2);
    try {
      final request = await client.getUrl(Uri.parse('http://${peer.host}:${peer.port}/?HOST_INFO'));
      request.persistentConnection = false;
      final response = await request.close().timeout(const Duration(seconds: 3));
      final body = await response.transform(utf8.decoder).join().timeout(const Duration(seconds: 3));
      final json = jsonDecode(body);
      if (json is Map) {
        final port = (json['OSC_PORT'] as num?)?.toInt();
        final host = json['OSC_IP'] as String?;
        final current = status.value;
        if (port != current.vrchatInputPort || host != current.vrchatInputHost) {
          status.value = LinkStatus(
            receiving: current.receiving,
            viaOscQuery: current.viaOscQuery,
            vrchat: current.vrchat ?? peer,
            vrchatInputPort: port,
            vrchatInputHost: host,
          );
        }
      }
    } catch (_) {
      // gone (VRChat closed without saying goodbye) - forget it.
      _service?.forgetPeer(peer);
      final current = status.value;
      status.value = LinkStatus(receiving: current.receiving, viaOscQuery: current.viaOscQuery);
    } finally {
      client.close(force: true);
      _verifying = false;
    }
  }

  /// forces a fresh look for VRChat right now (manual refresh button).
  void refreshNow() {
    _lastVerify = null;
    _lastQuery = null;
    _service?.queryPeers();
    _tickMonitor();
  }
}

/// a global singleton like themeSettingsNotifier, reachable from every screen.
final oscInputHub = OscInputHub();
