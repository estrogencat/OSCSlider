import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'crash_log.dart';

/// sends raw OSC packets on to a list of extra host:port destinations -
/// used to relay VRChat's output to apps that can't use OSCQuery, and to
/// mirror this app's own sends to a second device. failures are logged
/// (throttled) and otherwise ignored, same as every other OSC send.
class OscRelay {
  final String context;
  List<(String host, int port)> _targets = const [];
  final Map<String, InternetAddress> _resolved = {};
  final Map<String, DateTime> _failedLookups = {};
  RawDatagramSocket? _socket;
  Future<RawDatagramSocket>? _binding;
  bool _closed = false;

  OscRelay(this.context);

  bool get isEmpty => _targets.isEmpty;

  set targets(List<(String, int)> next) {
    _targets = List.unmodifiable(next);
  }

  void send(Uint8List packet) {
    if (_targets.isEmpty || _closed) return;
    for (final (host, port) in _targets) {
      unawaited(_sendTo(packet, host, port));
    }
  }

  Future<void> _sendTo(Uint8List packet, String host, int port) async {
    try {
      final address = await _resolve(host);
      if (address == null || _closed) return;
      final socket = await (_binding ??= RawDatagramSocket.bind(InternetAddress.anyIPv4, 0).then((s) {
        s.broadcastEnabled = true;
        return _socket = s;
      }));
      if (_closed) return;
      socket.send(packet, address, port);
    } catch (e, st) {
      unawaited(CrashLog.record(e, st, context: '$context -> $host:$port'));
    }
  }

  Future<InternetAddress?> _resolve(String host) async {
    final literal = InternetAddress.tryParse(host);
    if (literal != null) return literal;
    final cached = _resolved[host];
    if (cached != null) return cached;
    final failed = _failedLookups[host];
    if (failed != null && DateTime.now().difference(failed) < const Duration(seconds: 10)) return null;
    try {
      final list = await InternetAddress.lookup(host);
      final pick = list.firstWhere((a) => a.type == InternetAddressType.IPv4, orElse: () => list.first);
      return _resolved[host] = pick;
    } catch (_) {
      _failedLookups[host] = DateTime.now();
      return null;
    }
  }

  void close() {
    _closed = true;
    _socket?.close();
    _socket = null;
  }
}
