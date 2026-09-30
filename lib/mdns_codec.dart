import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

/// just enough of the DNS wire format (RFC 1035 + the mDNS bits of RFC 6762)
/// to answer and read OSCQuery service lookups - PTR/SRV/TXT/A records,
/// with compressed names on the way in, uncompressed on the way out.
class DnsType {
  static const a = 1;
  static const ptr = 12;
  static const txt = 16;
  static const aaaa = 28;
  static const srv = 33;
  static const any = 255;
}

const dnsClassIn = 1;
// top bit of a question's class = "unicast response please" (QU); top bit
// of a record's class = "cache flush" (this record replaces older ones).
const dnsClassTopBit = 0x8000;

class DnsQuestion {
  final String name;
  final int type;
  final bool unicastResponse;
  const DnsQuestion(this.name, this.type, {this.unicastResponse = false});
}

class DnsRecord {
  final String name;
  final int type;
  final int ttl;
  final bool cacheFlush;
  // decoded rdata for the types this app cares about.
  final String? ptrTarget;
  final int? srvPort;
  final String? srvTarget;
  final InternetAddress? address;
  final List<String> txt;

  const DnsRecord({
    required this.name,
    required this.type,
    required this.ttl,
    this.cacheFlush = false,
    this.ptrTarget,
    this.srvPort,
    this.srvTarget,
    this.address,
    this.txt = const [],
  });

  factory DnsRecord.ptr(String name, String target, {int ttl = 4500}) =>
      DnsRecord(name: name, type: DnsType.ptr, ttl: ttl, ptrTarget: target);

  factory DnsRecord.srv(String name, String target, int port, {int ttl = 120}) =>
      DnsRecord(name: name, type: DnsType.srv, ttl: ttl, cacheFlush: true, srvTarget: target, srvPort: port);

  factory DnsRecord.txt(String name, List<String> strings, {int ttl = 4500}) =>
      DnsRecord(name: name, type: DnsType.txt, ttl: ttl, cacheFlush: true, txt: strings);

  factory DnsRecord.a(String name, InternetAddress address, {int ttl = 120}) =>
      DnsRecord(name: name, type: DnsType.a, ttl: ttl, cacheFlush: true, address: address);

  DnsRecord withTtl(int newTtl) => DnsRecord(
        name: name,
        type: type,
        ttl: newTtl,
        cacheFlush: cacheFlush,
        ptrTarget: ptrTarget,
        srvPort: srvPort,
        srvTarget: srvTarget,
        address: address,
        txt: txt,
      );
}

class DnsMessage {
  final int id;
  final bool isResponse;
  final List<DnsQuestion> questions;
  final List<DnsRecord> answers;
  final List<DnsRecord> additionals;

  const DnsMessage({
    this.id = 0,
    required this.isResponse,
    this.questions = const [],
    this.answers = const [],
    this.additionals = const [],
  });

  Iterable<DnsRecord> get allRecords => answers.followedBy(additionals);
}

bool dnsNamesEqual(String a, String b) => a.toLowerCase() == b.toLowerCase();

class _Reader {
  final Uint8List data;
  final ByteData view;
  int offset = 0;
  _Reader(this.data) : view = ByteData.sublistView(data);

  int u8() => data[offset++];
  int u16() {
    final v = view.getUint16(offset, Endian.big);
    offset += 2;
    return v;
  }

  int u32() {
    final v = view.getUint32(offset, Endian.big);
    offset += 4;
    return v;
  }

  String name() {
    final labels = <String>[];
    var pos = offset;
    var jumped = false;
    // a compression pointer loop in a malformed packet would spin forever.
    var hops = 0;
    while (true) {
      if (pos >= data.length) throw const FormatException('name runs past end of packet');
      final len = data[pos];
      if (len == 0) {
        pos++;
        break;
      }
      if (len & 0xC0 == 0xC0) {
        if (pos + 1 >= data.length) throw const FormatException('truncated name pointer');
        final target = ((len & 0x3F) << 8) | data[pos + 1];
        if (!jumped) offset = pos + 2;
        jumped = true;
        pos = target;
        if (++hops > 64) throw const FormatException('name pointer loop');
        continue;
      }
      if (len & 0xC0 != 0) throw const FormatException('unsupported label type');
      final start = pos + 1;
      final end = start + len;
      if (end > data.length) throw const FormatException('label runs past end of packet');
      labels.add(utf8.decode(Uint8List.sublistView(data, start, end), allowMalformed: true));
      pos = end;
    }
    if (!jumped) offset = pos;
    return labels.join('.');
  }
}

/// null if [data] isn't a parseable DNS message.
DnsMessage? decodeDnsMessage(Uint8List data) {
  try {
    final r = _Reader(data);
    final id = r.u16();
    final flags = r.u16();
    final qd = r.u16();
    final an = r.u16();
    final ns = r.u16();
    final ar = r.u16();

    final questions = <DnsQuestion>[];
    for (var i = 0; i < qd; i++) {
      final name = r.name();
      final type = r.u16();
      final klass = r.u16();
      questions.add(DnsQuestion(name, type, unicastResponse: klass & dnsClassTopBit != 0));
    }

    List<DnsRecord> readRecords(int count) {
      final out = <DnsRecord>[];
      for (var i = 0; i < count; i++) {
        final name = r.name();
        final type = r.u16();
        final klass = r.u16();
        final ttl = r.u32();
        final rdlen = r.u16();
        final rdStart = r.offset;
        final rdEnd = rdStart + rdlen;
        if (rdEnd > data.length) throw const FormatException('rdata runs past end of packet');
        String? ptrTarget;
        int? srvPort;
        String? srvTarget;
        InternetAddress? address;
        var txt = const <String>[];
        switch (type) {
          case DnsType.ptr:
            ptrTarget = r.name();
          case DnsType.srv:
            r.u16(); // priority
            r.u16(); // weight
            srvPort = r.u16();
            srvTarget = r.name();
          case DnsType.a:
            if (rdlen == 4) address = InternetAddress.fromRawAddress(Uint8List.fromList(data.sublist(rdStart, rdEnd)));
          case DnsType.aaaa:
            if (rdlen == 16) address = InternetAddress.fromRawAddress(Uint8List.fromList(data.sublist(rdStart, rdEnd)));
          case DnsType.txt:
            final strings = <String>[];
            var p = rdStart;
            while (p < rdEnd) {
              final len = data[p];
              final end = (p + 1 + len).clamp(0, rdEnd);
              strings.add(utf8.decode(data.sublist(p + 1, end), allowMalformed: true));
              p = end;
            }
            txt = strings;
        }
        r.offset = rdEnd;
        out.add(DnsRecord(
          name: name,
          type: type,
          ttl: ttl,
          cacheFlush: klass & dnsClassTopBit != 0,
          ptrTarget: ptrTarget,
          srvPort: srvPort,
          srvTarget: srvTarget,
          address: address,
          txt: txt,
        ));
      }
      return out;
    }

    final answers = readRecords(an);
    // authority records only matter for probing, which this app skips.
    readRecords(ns);
    final additionals = readRecords(ar);
    return DnsMessage(
      id: id,
      isResponse: flags & 0x8000 != 0,
      questions: questions,
      answers: answers,
      additionals: additionals,
    );
  } catch (_) {
    return null;
  }
}

Uint8List encodeDnsMessage(DnsMessage message) {
  final out = BytesBuilder();
  void u16(int v) => out.add([(v >> 8) & 0xFF, v & 0xFF]);
  void u32(int v) => out.add([(v >> 24) & 0xFF, (v >> 16) & 0xFF, (v >> 8) & 0xFF, v & 0xFF]);

  Uint8List nameBytes(String name) {
    final b = BytesBuilder();
    for (final label in name.split('.')) {
      if (label.isEmpty) continue;
      var bytes = utf8.encode(label);
      if (bytes.length > 63) bytes = bytes.sublist(0, 63);
      b.addByte(bytes.length);
      b.add(bytes);
    }
    b.addByte(0);
    return b.toBytes();
  }

  u16(message.id);
  // responses are always authoritative answers in mDNS.
  u16(message.isResponse ? 0x8400 : 0x0000);
  u16(message.questions.length);
  u16(message.answers.length);
  u16(0);
  u16(message.additionals.length);

  for (final q in message.questions) {
    out.add(nameBytes(q.name));
    u16(q.type);
    u16(dnsClassIn | (q.unicastResponse ? dnsClassTopBit : 0));
  }

  for (final rec in message.answers.followedBy(message.additionals)) {
    out.add(nameBytes(rec.name));
    u16(rec.type);
    u16(dnsClassIn | (rec.cacheFlush ? dnsClassTopBit : 0));
    u32(rec.ttl);
    final rdata = BytesBuilder();
    switch (rec.type) {
      case DnsType.ptr:
        rdata.add(nameBytes(rec.ptrTarget!));
      case DnsType.srv:
        rdata.add([0, 0, 0, 0, (rec.srvPort! >> 8) & 0xFF, rec.srvPort! & 0xFF]);
        rdata.add(nameBytes(rec.srvTarget!));
      case DnsType.a || DnsType.aaaa:
        rdata.add(rec.address!.rawAddress);
      case DnsType.txt:
        final strings = rec.txt.isEmpty ? const [''] : rec.txt;
        for (final s in strings) {
          var bytes = utf8.encode(s);
          if (bytes.length > 255) bytes = bytes.sublist(0, 255);
          rdata.addByte(bytes.length);
          rdata.add(bytes);
        }
    }
    final rd = rdata.toBytes();
    u16(rd.length);
    out.add(rd);
  }
  return out.toBytes();
}
