import 'dart:convert';
import 'dart:typed_data';

class OscMessage {
  final String address;
  final List<Object> args;
  OscMessage(this.address, this.args);
}

/// decodes one UDP datagram into its OSC messages - a plain message gives
/// one, a #bundle gives every message inside it (nested bundles included).
/// malformed data yields whatever parsed cleanly before the damage.
List<OscMessage> parseOscPacket(Uint8List data) {
  final out = <OscMessage>[];
  _parseElement(data, out, 0);
  return out;
}

/// single-message convenience wrapper - the first message in the packet.
OscMessage? parseOscMessage(Uint8List data) {
  final all = parseOscPacket(data);
  return all.isEmpty ? null : all.first;
}

const _maxBundleDepth = 8;

void _parseElement(Uint8List data, List<OscMessage> out, int depth) {
  if (data.isEmpty || depth > _maxBundleDepth) return;
  if (data[0] == 0x23 /* '#' */) {
    _parseBundle(data, out, depth);
    return;
  }
  final msg = _parseMessage(data);
  if (msg != null) out.add(msg);
}

void _parseBundle(Uint8List data, List<OscMessage> out, int depth) {
  // "#bundle\0" + 8-byte time tag, then (int32 size, element) pairs.
  if (data.length < 16) return;
  final header = ascii.decode(data.sublist(0, 7), allowInvalid: true);
  if (header != '#bundle') return;
  final view = ByteData.sublistView(data);
  var offset = 16;
  while (offset + 4 <= data.length) {
    final size = view.getInt32(offset, Endian.big);
    offset += 4;
    if (size <= 0 || offset + size > data.length) return;
    _parseElement(Uint8List.sublistView(data, offset, offset + size), out, depth + 1);
    offset += size;
  }
}

OscMessage? _parseMessage(Uint8List data) {
  try {
    var offset = 0;

    // OSC strings are UTF-8 in practice (VRChat allows non-ASCII parameter
    // names), null-terminated and padded to a 4-byte boundary.
    String readString() {
      final start = offset;
      while (data[offset] != 0) {
        offset++;
      }
      final s = utf8.decode(Uint8List.sublistView(data, start, offset), allowMalformed: true);
      offset++;
      while (offset % 4 != 0) {
        offset++;
      }
      return s;
    }

    final address = readString();
    if (!address.startsWith('/')) return null;
    if (offset >= data.length || data[offset] != 0x2C /* ',' */) {
      return OscMessage(address, const []);
    }

    final typeTags = readString().substring(1);
    final args = <Object>[];
    final view = ByteData.sublistView(data);
    for (final t in typeTags.split('')) {
      switch (t) {
        case 'i':
          args.add(view.getInt32(offset, Endian.big));
          offset += 4;
        case 'f':
          args.add(view.getFloat32(offset, Endian.big));
          offset += 4;
        case 'h':
          args.add(view.getInt64(offset, Endian.big));
          offset += 8;
        case 'd':
          args.add(view.getFloat64(offset, Endian.big));
          offset += 8;
        case 't':
          args.add(view.getUint64(offset, Endian.big));
          offset += 8;
        case 'c':
          args.add(String.fromCharCode(view.getInt32(offset, Endian.big)));
          offset += 4;
        case 'r' || 'm':
          args.add(Uint8List.fromList(data.sublist(offset, offset + 4)));
          offset += 4;
        case 's' || 'S':
          args.add(readString());
        case 'b':
          final len = view.getInt32(offset, Endian.big);
          offset += 4;
          args.add(Uint8List.fromList(data.sublist(offset, offset + len)));
          offset += len;
          while (offset % 4 != 0) {
            offset++;
          }
        case 'T':
          args.add(true);
        case 'F':
          args.add(false);
        case 'N' || 'I' || '[' || ']':
          // no payload, and nothing useful to hand back for them.
          break;
        default:
          // unknown tag - its payload size is unknown too, so stop here
          // rather than misread everything after it.
          return OscMessage(address, args);
      }
    }
    return OscMessage(address, args);
  } catch (_) {
    return null;
  }
}
