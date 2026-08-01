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

  Future<void> sendInt64(String address, int value) async {
    await _send(address, _oscString(',h'), (ByteData(8)..setInt64(0, value, Endian.big)).buffer.asUint8List());
  }

  // OSC's "Symbol" - wire-identical to a string, just tagged distinctly for
  // receivers that treat symbols and strings as separate concepts.
  Future<void> sendSymbol(String address, String value) async {
    await _send(address, _oscString(',S'), _oscString(value));
  }

  // sent as a 32-bit int carrying the character's code point, per the OSC spec.
  Future<void> sendChar(String address, String char) async {
    if (char.isEmpty) throw OscSendException('char value is empty');
    await _send(
        address, _oscString(',c'), (ByteData(4)..setInt32(0, char.runes.first, Endian.big)).buffer.asUint8List());
  }

  Future<void> sendRgba(String address, int r, int g, int b, int a) async {
    await _send(address, _oscString(',r'), Uint8List.fromList([r, g, b, a]));
  }

  Future<void> sendMidi(String address, int port, int status, int data1, int data2) async {
    await _send(address, _oscString(',m'), Uint8List.fromList([port, status, data1, data2]));
  }

  // length-prefixed raw bytes, padded to a 4-byte boundary same as strings.
  Future<void> sendBlob(String address, Uint8List bytes) async {
    final header = ByteData(4)..setInt32(0, bytes.length, Endian.big);
    final paddedLen = (bytes.length % 4 == 0) ? bytes.length : bytes.length + (4 - bytes.length % 4);
    final padded = Uint8List(paddedLen)..setRange(0, bytes.length, bytes);
    await _send(address, _oscString(',b'), Uint8List.fromList([...header.buffer.asUint8List(), ...padded]));
  }

  // OSC-timetag: 32-bit seconds since 1900-01-01 + 32-bit fractional seconds.
  // the all-zero-except-LSB value (1) is the spec's special "immediately".
  Future<void> sendTimeTag(String address, double secondsSince1900) async {
    final seconds = secondsSince1900.floor();
    final frac = ((secondsSince1900 - seconds) * 4294967296.0).round();
    final bytes = ByteData(8)
      ..setUint32(0, seconds, Endian.big)
      ..setUint32(4, frac, Endian.big);
    await _send(address, _oscString(',t'), bytes.buffer.asUint8List());
  }

  Future<void> sendImmediateTimeTag(String address) async {
    final bytes = ByteData(8)..setUint64(0, 1, Endian.big);
    await _send(address, _oscString(',t'), bytes.buffer.asUint8List());
  }

  // Nil/Infinitum carry no payload bytes, same as True/False.
  Future<void> sendNil(String address) async {
    await _send(address, _oscString(',N'), Uint8List(0));
  }

  Future<void> sendInfinitum(String address) async {
    await _send(address, _oscString(',I'), Uint8List(0));
  }

  /// dispatches every OSC 1.0/1.1 type tag except arrays (which don't fit
  /// this app's one-parameter-one-value model), so the app can send types it
  /// has no dedicated slider/toggle widget for.
  Future<void> sendCustom(String address, String typeTag, String valueText) async {
    switch (typeTag) {
      case 'f':
        await sendFloat(address, double.parse(valueText));
      case 'i':
        await sendInt(address, int.parse(valueText));
      case 'd':
        await sendDouble(address, double.parse(valueText));
      case 'h':
        await sendInt64(address, int.parse(valueText));
      case 's':
        await sendString(address, valueText);
      case 'S':
        await sendSymbol(address, valueText);
      case 'c':
        await sendChar(address, valueText);
      case 'r':
        final bytes = _parseHexBytes(valueText, 4, 'RGBA color');
        await sendRgba(address, bytes[0], bytes[1], bytes[2], bytes[3]);
      case 'm':
        final bytes = _parseHexBytes(valueText, 4, 'MIDI message');
        await sendMidi(address, bytes[0], bytes[1], bytes[2], bytes[3]);
      case 'b':
        await sendBlob(address, Uint8List.fromList(_parseHex(valueText)));
      case 't':
        if (valueText.trim().toLowerCase() == 'immediate') {
          await sendImmediateTimeTag(address);
        } else {
          await sendTimeTag(address, double.parse(valueText));
        }
      case 'T':
        await sendBool(address, true);
      case 'F':
        await sendBool(address, false);
      case 'N':
        await sendNil(address);
      case 'I':
        await sendInfinitum(address);
      default:
        throw OscSendException('unsupported OSC type tag "$typeTag"');
    }
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
