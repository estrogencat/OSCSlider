import 'dart:io';
import 'dart:typed_data';

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

  OscClient({required this.host, required this.port});

  Future<void> sendFloat(String address, double value) async {
    await _send(address, _oscString(',f'), (ByteData(4)..setFloat32(0, value, Endian.big)).buffer.asUint8List());
  }

  Future<void> sendInt(String address, int value) async {
    await _send(address, _oscString(',i'), (ByteData(4)..setInt32(0, value, Endian.big)).buffer.asUint8List());
  }

  Future<void> sendDouble(String address, double value) async {
    await _send(address, _oscString(',d'), (ByteData(8)..setFloat64(0, value, Endian.big)).buffer.asUint8List());
  }

  Future<void> sendString(String address, String value) async {
    await _send(address, _oscString(',s'), _oscString(value));
  }

  // bool args carry no payload bytes - the type tag itself ('T' or 'F') is the value.
  Future<void> sendBool(String address, bool value) async {
    await _send(address, _oscString(value ? ',T' : ',F'), Uint8List(0));
  }

  /// best-effort dispatch for a freeform type tag typed by the user, so the
  /// app can send types it has no dedicated widget for (or future OSC types).
  Future<void> sendCustom(String address, String typeTag, String valueText) async {
    switch (typeTag) {
      case 'f':
        await sendFloat(address, double.parse(valueText));
      case 'i':
        await sendInt(address, int.parse(valueText));
      case 'd':
        await sendDouble(address, double.parse(valueText));
      case 's':
        await sendString(address, valueText);
      case 'T':
        await sendBool(address, true);
      case 'F':
        await sendBool(address, false);
      default:
        throw OscSendException('unsupported OSC type tag "$typeTag"');
    }
  }

  Future<void> _send(String address, Uint8List typeTagBytes, Uint8List argBytes) async {
    _socket ??= await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
    final out = BytesBuilder();
    out.add(_oscString(address));
    out.add(typeTagBytes);
    out.add(argBytes);
    _socket!.send(out.toBytes(), InternetAddress(host), port);
  }

  // null-terminated ASCII string, padded to a 4-byte boundary per the OSC spec.
  static Uint8List _oscString(String s) {
    final raw = <int>[...s.codeUnits, 0];
    final paddedLen = (raw.length % 4 == 0) ? raw.length : raw.length + (4 - raw.length % 4);
    final out = Uint8List(paddedLen);
    out.setRange(0, raw.length, raw);
    return out;
  }

  void dispose() {
    _socket?.close();
    _socket = null;
  }
}
