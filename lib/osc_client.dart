import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';

import 'crash_log.dart';
import 'osc_relay.dart';

class OscSendException implements Exception {
  final String message;
  OscSendException(this.message);
  @override
  String toString() => message;
}

/// minimal OSC 1.0 UDP sender for VRChat's avatar parameter endpoint
/// (/avatar/parameters/name). covers float/int/bool (VRChat's real types),
/// plus double/string and a raw type-tag dispatcher for anything else.
class OscClient {
  final String host;
  final int port;
  RawDatagramSocket? _socket;
  // shared by every send that races the first bind, so a burst of sends
  // before the socket exists can't each open (and leak) their own socket.
  Future<RawDatagramSocket>? _socketFuture;
  Future<InternetAddress>? _targetFuture;
  DateTime? _lookupFailedAt;
  bool _disposed = false;

  /// extra destinations every send is copied to (Settings > Forwarding).
  final OscRelay mirror = OscRelay('OSC mirror');

  /// the most recent send failure (null once a send succeeds again) - lets
  /// the UI say "can't reach host" instead of failing silently.
  final ValueNotifier<String?> lastError = ValueNotifier(null);

  OscClient({required this.host, required this.port});

  Future<void> sendFloat(String address, double value) =>
      _send(address, ',f', (ByteData(4)..setFloat32(0, value, Endian.big)).buffer.asUint8List());

  Future<void> sendInt(String address, int value) =>
      _send(address, ',i', (ByteData(4)..setInt32(0, value, Endian.big)).buffer.asUint8List());

  Future<void> sendDouble(String address, double value, {bool surfaceErrors = false}) => _send(
      address, ',d', (ByteData(8)..setFloat64(0, value, Endian.big)).buffer.asUint8List(),
      surfaceErrors: surfaceErrors);

  Future<void> sendString(String address, String value, {bool surfaceErrors = false}) =>
      _send(address, ',s', oscString(value), surfaceErrors: surfaceErrors);

  // bool args carry no payload bytes - the type tag itself ('T' or 'F') is the value.
  Future<void> sendBool(String address, bool value, {bool surfaceErrors = false}) =>
      _send(address, value ? ',T' : ',F', Uint8List(0), surfaceErrors: surfaceErrors);

  /// VRChat's chatbox: /chatbox/input s b n - [sendNow] false just opens
  /// the in-game keyboard pre-filled, [notify] false skips the sound.
  Future<void> sendChatbox(String address, String text, {required bool sendNow, required bool notify}) =>
      _send(address, ',s${sendNow ? 'T' : 'F'}${notify ? 'T' : 'F'}', oscString(text), surfaceErrors: true);

  /// dispatches every OSC 1.0/1.1 type tag except arrays (which don't fit
  /// this app's one-parameter-one-value model), so the app can send types it
  /// has no dedicated slider/toggle widget for. throws on bad input or a
  /// failed send, since this is only ever triggered by hand.
  Future<void> sendCustom(String address, String typeTag, String valueText) async {
    final payload = encodeCustomArgument(typeTag, valueText);
    await _send(address, ',$typeTag', payload, surfaceErrors: true);
  }

  /// the wire bytes for one argument of [typeTag] parsed from [valueText] -
  /// exposed separately so the parameter form can validate before saving.
  static Uint8List encodeCustomArgument(String typeTag, String valueText) {
    final text = valueText.trim();
    ByteData bytes(int n) => ByteData(n);
    switch (typeTag) {
      case 'f':
        return (bytes(4)..setFloat32(0, _parseDouble(text), Endian.big)).buffer.asUint8List();
      case 'i':
        return (bytes(4)..setInt32(0, _parseInt(text, 32), Endian.big)).buffer.asUint8List();
      case 'd':
        return (bytes(8)..setFloat64(0, _parseDouble(text), Endian.big)).buffer.asUint8List();
      case 'h':
        return (bytes(8)..setInt64(0, _parseInt(text, 64), Endian.big)).buffer.asUint8List();
      case 's' || 'S':
        // OSC's "Symbol" is wire-identical to a string, just tagged distinctly
        // for receivers that treat symbols and strings as separate concepts.
        return oscString(valueText);
      case 'c':
        // sent as a 32-bit int carrying the character's code point.
        if (valueText.isEmpty) throw OscSendException('char value is empty');
        return (bytes(4)..setInt32(0, valueText.runes.first, Endian.big)).buffer.asUint8List();
      case 'r':
        return Uint8List.fromList(_parseHexBytes(text, 4, 'RGBA color'));
      case 'm':
        return Uint8List.fromList(_parseHexBytes(text, 4, 'MIDI message'));
      case 'b':
        // length-prefixed raw bytes, padded to a 4-byte boundary same as strings.
        final raw = _parseHex(text);
        final header = ByteData(4)..setInt32(0, raw.length, Endian.big);
        final paddedLen = (raw.length + 3) & ~3;
        final padded = Uint8List(paddedLen)..setRange(0, raw.length, raw);
        return Uint8List.fromList([...header.buffer.asUint8List(), ...padded]);
      case 't':
        // OSC-timetag: 32-bit seconds since 1900-01-01 + 32-bit fractional
        // seconds. the all-zero-except-LSB value is the spec's "immediately".
        final out = ByteData(8);
        if (text.toLowerCase() == 'immediate') {
          out.setUint64(0, 1, Endian.big);
        } else {
          final secondsSince1900 = _parseDouble(text);
          if (secondsSince1900 < 0 || secondsSince1900 >= 4294967296.0) {
            throw OscSendException('time tag must be between 0 and 4294967295 seconds');
          }
          final seconds = secondsSince1900.floor();
          final frac = ((secondsSince1900 - seconds) * 4294967296.0).floor().clamp(0, 0xFFFFFFFF);
          out
            ..setUint32(0, seconds, Endian.big)
            ..setUint32(4, frac, Endian.big);
        }
        return out.buffer.asUint8List();
      case 'T' || 'F' || 'N' || 'I':
        // True/False/Nil/Infinitum carry no payload bytes.
        return Uint8List(0);
      default:
        throw OscSendException('unsupported OSC type tag "$typeTag"');
    }
  }

  static double _parseDouble(String text) {
    final v = double.tryParse(text);
    if (v == null) throw OscSendException('"$text" is not a number');
    return v;
  }

  static int _parseInt(String text, int bits) {
    final v = int.tryParse(text);
    if (v == null) throw OscSendException('"$text" is not a whole number');
    if (bits == 32 && (v < -2147483648 || v > 2147483647)) {
      throw OscSendException('$v doesn\'t fit in a 32-bit int');
    }
    return v;
  }

  static List<int> _parseHex(String text) {
    final cleaned = text.replaceAll(RegExp(r'[^0-9a-fA-F]'), '');
    if (cleaned.length % 2 != 0) throw OscSendException('hex value must have an even number of digits');
    return [for (var i = 0; i < cleaned.length; i += 2) int.parse(cleaned.substring(i, i + 2), radix: 16)];
  }

  static List<int> _parseHexBytes(String text, int count, String label) {
    final bytes = _parseHex(text);
    if (bytes.length != count) throw OscSendException('$label needs exactly $count bytes ($count hex byte pairs)');
    return bytes;
  }

  /// a complete OSC message for [address] carrying [typeTags]/[argBytes].
  static Uint8List encodeMessage(String address, String typeTags, Uint8List argBytes) {
    return (BytesBuilder(copy: false)
          ..add(oscString(address))
          ..add(oscString(typeTags))
          ..add(argBytes))
        .toBytes();
  }

  // UTF-8, null-terminated, padded to a 4-byte boundary per the OSC spec -
  // UTF-8 rather than raw code units, or any non-ASCII parameter name (e.g.
  // Japanese) would be mangled into an address VRChat can't match.
  static Uint8List oscString(String s) {
    final raw = utf8.encode(s);
    final out = Uint8List((raw.length + 4) & ~3);
    out.setRange(0, raw.length, raw);
    return out;
  }

  Future<InternetAddress> _target() {
    // hostnames ("localhost", a PC name) need a lookup - InternetAddress()
    // alone only accepts numeric IPs and used to throw on every send.
    final literal = InternetAddress.tryParse(host);
    if (literal != null) return _targetFuture ??= Future.value(literal);
    // retry a failed lookup at most every few seconds instead of every send.
    if (_targetFuture == null ||
        (_lookupFailedAt != null && DateTime.now().difference(_lookupFailedAt!) > const Duration(seconds: 5))) {
      _lookupFailedAt = null;
      _targetFuture = InternetAddress.lookup(host).then((list) {
        if (list.isEmpty) throw OscSendException('could not resolve "$host"');
        return list.firstWhere((a) => a.type == InternetAddressType.IPv4, orElse: () => list.first);
      }).catchError((Object e) {
        _lookupFailedAt = DateTime.now();
        throw OscSendException('could not resolve host "$host": $e');
      });
    }
    return _targetFuture!;
  }

  Future<RawDatagramSocket> _bindFor(InternetAddress target) {
    return _socketFuture ??= RawDatagramSocket.bind(
      target.type == InternetAddressType.IPv6 ? InternetAddress.anyIPv6 : InternetAddress.anyIPv4,
      0,
    ).then((socket) {
      // lets a subnet broadcast address (e.g. 192.168.1.255) work as a host.
      socket.broadcastEnabled = true;
      if (_disposed) {
        socket.close();
      } else {
        _socket = socket;
      }
      return socket;
    }).catchError((Object e) {
      _socketFuture = null;
      throw e;
    });
  }

  // sends fire hundreds of times a second (every automation tick, every
  // slider drag) and are almost always unawaited - OSC is inherently
  // fire-and-forget, so a failed send is just recorded (throttled), not
  // surfaced as an unhandled async error that could take the whole app down.
  Future<void> _send(String address, String typeTags, Uint8List argBytes, {bool surfaceErrors = false}) async {
    if (_disposed) return;
    try {
      if (port < 1 || port > 65535) throw OscSendException('port $port is out of range (1-65535)');
      final packet = encodeMessage(address, typeTags, argBytes);
      if (packet.length > 65000) throw OscSendException('message is too large for one UDP packet');
      final target = await _target();
      final socket = await _bindFor(target);
      if (_disposed) return;
      final sent = socket.send(packet, target, port);
      mirror.send(packet);
      if (sent == 0) throw OscSendException('send buffer full - packet dropped');
      if (lastError.value != null) lastError.value = null;
    } catch (e, st) {
      if (!_disposed) lastError.value = e.toString();
      if (surfaceErrors) rethrow;
      unawaited(CrashLog.record(e, st, context: 'OscClient send $address'));
    }
  }

  void dispose() {
    _disposed = true;
    mirror.close();
    _socket?.close();
    _socket = null;
    lastError.dispose();
  }
}
