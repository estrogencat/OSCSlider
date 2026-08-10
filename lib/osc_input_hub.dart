import 'dart:async';
import 'dart:io';

import 'crash_log.dart';
import 'osc_listener.dart';

/// single shared socket for VRChat's outgoing OSC traffic - Windows doesn't
/// reliably fan unicast UDP out to more than one socket bound to the same
/// port even with reuseAddress, so every feature (Auto Profile Mode, the
/// discover popup's live listener, avatar-id caching) shares this one socket
/// and its broadcast stream instead of each binding their own and starving
/// each other. a global singleton like themeSettingsNotifier, reachable from
/// every screen.
class OscInputHub {
  RawDatagramSocket? _socket;
  int _refCount = 0;
  // in-flight bind, so concurrent acquire() calls (no await between them)
  // share one bind attempt instead of each racing to bind the same port.
  Future<RawDatagramSocket?>? _binding;
  final _controller = StreamController<OscMessage>.broadcast();

  Stream<OscMessage> get messages => _controller.stream;

  /// starts the shared socket if it isn't already running, and increments
  /// the ref count - call [release] once done so it can shut down when
  /// nothing else needs it. returns false only if a fresh bind fails.
  Future<bool> acquire(int port) async {
    _refCount++;
    if (_socket != null) return true;
    _binding ??= _bind(port);
    final socket = await _binding;
    if (socket == null) {
      _refCount--;
      return false;
    }
    return true;
  }

  Future<RawDatagramSocket?> _bind(int port) async {
    try {
      final socket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, port, reuseAddress: true);
      socket.listen(
        (event) {
          if (event == RawSocketEvent.closed) {
            // let a future acquire() rebind fresh instead of silently
            // sitting on a dead socket for the rest of the session.
            if (identical(_socket, socket)) _socket = null;
            return;
          }
          if (event != RawSocketEvent.read) return;
          final datagram = socket.receive();
          if (datagram == null) return;
          final msg = parseOscMessage(datagram.data);
          if (msg != null) _controller.add(msg);
        },
        onError: (Object e, StackTrace st) => CrashLog.record(e, st, context: 'OscInputHub port $port'),
      );
      _socket = socket;
      return socket;
    } catch (_) {
      return null;
    } finally {
      _binding = null;
    }
  }

  void release() {
    if (_refCount <= 0) return;
    _refCount--;
    if (_refCount == 0) {
      _socket?.close();
      _socket = null;
    }
  }
}

final oscInputHub = OscInputHub();
