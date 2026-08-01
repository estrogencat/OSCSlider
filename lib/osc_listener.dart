import 'dart:io';
import 'dart:typed_data';

class OscMessage {
  final String address;
  final List<Object> args;
  OscMessage(this.address, this.args);
}

/// minimal OSC decoder - just enough to recognize /avatar/change and its
/// string argument. unknown type tags stop argument parsing early rather
/// than risk misreading the rest of the packet.
OscMessage? parseOscMessage(Uint8List data) {
  try {
    var offset = 0;

    String readString() {
      final start = offset;
      while (data[offset] != 0) {
        offset++;
      }
      final s = String.fromCharCodes(data, start, offset);
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
        case 'd':
          args.add(view.getFloat64(offset, Endian.big));
          offset += 8;
        case 's':
          args.add(readString());
        case 'T':
          args.add(true);
        case 'F':
          args.add(false);
        default:
          return OscMessage(address, args);
      }
    }
    return OscMessage(address, args);
  } catch (_) {
    return null;
  }
}

/// listens for VRChat's outgoing /avatar/change {avatarId} notification so
/// auto mode can react to avatar switches.
class AvatarChangeListener {
  RawDatagramSocket? _socket;

  Future<void> start(int port, void Function(String avatarId) onAvatarChange) async {
    _socket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, port, reuseAddress: true);
    _socket!.listen((event) {
      if (event != RawSocketEvent.read) return;
      final datagram = _socket?.receive();
      if (datagram == null) return;
      final msg = parseOscMessage(datagram.data);
      if (msg == null || msg.address != '/avatar/change') return;
      if (msg.args.isEmpty || msg.args.first is! String) return;
      onAvatarChange(msg.args.first as String);
    });
  }

  void stop() {
    _socket?.close();
    _socket = null;
  }
}
