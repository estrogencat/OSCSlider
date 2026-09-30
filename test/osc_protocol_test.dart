import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:osc_slider/mdns_codec.dart';
import 'package:osc_slider/osc_client.dart';
import 'package:osc_slider/osc_listener.dart';
import 'package:osc_slider/oscquery_client.dart';
import 'package:osc_slider/vrchat_files.dart';

Uint8List _msg(String address, String tags, List<int> args) =>
    OscClient.encodeMessage(address, tags, Uint8List.fromList(args));

void main() {
  group('OSC encode/decode', () {
    test('float round trip', () {
      final bytes = OscClient.encodeMessage(
        '/avatar/parameters/Test',
        ',f',
        (ByteData(4)..setFloat32(0, 0.5, Endian.big)).buffer.asUint8List(),
      );
      expect(bytes.length % 4, 0);
      final msg = parseOscMessage(bytes)!;
      expect(msg.address, '/avatar/parameters/Test');
      expect(msg.args.single, 0.5);
    });

    test('non-ASCII addresses survive as UTF-8', () {
      const address = '/avatar/parameters/しっぽ/揺れ';
      final bytes = _msg(address, ',T', []);
      // every byte is a real UTF-8 byte, not a truncated UTF-16 code unit.
      expect(bytes.sublist(0, 20), isNot(contains(0)));
      final msg = parseOscMessage(bytes)!;
      expect(msg.address, address);
      expect(msg.args.single, true);
    });

    test('bundles are unpacked', () {
      final a = _msg('/a', ',i', [0, 0, 0, 7]);
      final b = _msg('/b', ',F', []);
      final bundle = BytesBuilder()
        ..add(OscClient.oscString('#bundle'))
        ..add(List.filled(8, 0))
        ..add((ByteData(4)..setInt32(0, a.length)).buffer.asUint8List())
        ..add(a)
        ..add((ByteData(4)..setInt32(0, b.length)).buffer.asUint8List())
        ..add(b);
      final msgs = parseOscPacket(bundle.toBytes());
      expect(msgs.map((m) => m.address), ['/a', '/b']);
      expect(msgs[0].args.single, 7);
      expect(msgs[1].args.single, false);
    });

    test('strings and trailing args after a string parse', () {
      final bytes = OscClient.encodeMessage(
        '/avatar/change',
        ',si',
        Uint8List.fromList([...OscClient.oscString('avtr_123'), 0, 0, 0, 1]),
      );
      final msg = parseOscMessage(bytes)!;
      expect(msg.args, ['avtr_123', 1]);
    });

    test('garbage is rejected, not thrown', () {
      expect(parseOscPacket(Uint8List.fromList([1, 2, 3])), isEmpty);
      expect(parseOscPacket(Uint8List(0)), isEmpty);
      expect(parseOscPacket(Uint8List.fromList('#bundle'.codeUnits)), isEmpty);
    });

    test('custom argument encoding validates input', () {
      expect(OscClient.encodeCustomArgument('i', '42'), [0, 0, 0, 42]);
      expect(() => OscClient.encodeCustomArgument('i', '99999999999'), throwsA(isA<OscSendException>()));
      expect(() => OscClient.encodeCustomArgument('f', 'abc'), throwsA(isA<OscSendException>()));
      expect(OscClient.encodeCustomArgument('r', 'FF00FF80'), [255, 0, 255, 128]);
      expect(OscClient.encodeCustomArgument('b', 'DEAD').length, 8);
      expect(() => OscClient.encodeCustomArgument('t', '-5'), throwsA(isA<OscSendException>()));
      expect(OscClient.encodeCustomArgument('T', ''), isEmpty);
    });

    test('sends to a host name, not just an IP', () async {
      final receiver = await RawDatagramSocket.bind(InternetAddress.loopbackIPv4, 0);
      final got = receiver.where((e) => e == RawSocketEvent.read).map((_) => receiver.receive()).first;
      final client = OscClient(host: 'localhost', port: receiver.port);
      await client.sendFloat('/x', 1.0);
      final dg = await got.timeout(const Duration(seconds: 5));
      expect(parseOscMessage(dg!.data)!.address, '/x');
      expect(client.lastError.value, isNull);
      client.dispose();
      receiver.close();
    });

    test('a bad port is reported, not thrown', () async {
      final client = OscClient(host: '127.0.0.1', port: 70000);
      await client.sendFloat('/x', 1.0);
      expect(client.lastError.value, contains('out of range'));
      client.dispose();
    });
  });

  group('mDNS codec', () {
    test('response round trip', () {
      final msg = DnsMessage(
        isResponse: true,
        answers: [DnsRecord.ptr('_oscjson._tcp.local', 'VRChat-Client-ABC._oscjson._tcp.local')],
        additionals: [
          DnsRecord.srv('VRChat-Client-ABC._oscjson._tcp.local', 'VRChat-Client-ABC.oscjson.local', 51234),
          DnsRecord.txt('VRChat-Client-ABC._oscjson._tcp.local', const ['txtvers=1']),
          DnsRecord.a('VRChat-Client-ABC.oscjson.local', InternetAddress.loopbackIPv4),
        ],
      );
      final decoded = decodeDnsMessage(encodeDnsMessage(msg))!;
      expect(decoded.isResponse, true);
      expect(decoded.answers.single.ptrTarget, 'VRChat-Client-ABC._oscjson._tcp.local');
      final srv = decoded.additionals.firstWhere((r) => r.type == DnsType.srv);
      expect(srv.srvPort, 51234);
      expect(srv.cacheFlush, true);
      expect(decoded.additionals.firstWhere((r) => r.type == DnsType.a).address, InternetAddress.loopbackIPv4);
      expect(decoded.additionals.firstWhere((r) => r.type == DnsType.txt).txt, ['txtvers=1']);
    });

    test('compressed names are followed', () {
      // header, then one PTR answer: name "_x._tcp.local" and a target that
      // points back into it ("inst" + pointer to offset 12).
      final name = [2, 95, 120, 4, 95, 116, 99, 112, 5, 108, 111, 99, 97, 108, 0];
      final rdata = [4, 105, 110, 115, 116, 0xC0, 12];
      final bytes = Uint8List.fromList([
        0, 0, 0x84, 0, 0, 0, 0, 1, 0, 0, 0, 0, //
        ...name,
        0, 12, 0, 1, 0, 0, 0, 120, 0, rdata.length,
        ...rdata,
      ]);
      final decoded = decodeDnsMessage(bytes)!;
      expect(decoded.answers.single.name, '_x._tcp.local');
      expect(decoded.answers.single.ptrTarget, 'inst._x._tcp.local');
    });

    test('pointer loops are rejected instead of hanging', () {
      final bytes = Uint8List.fromList([0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0, 0xC0, 12, 0, 12, 0, 1]);
      expect(decodeDnsMessage(bytes), isNull);
    });
  });

  group('OSCQuery values', () {
    test('VRChat bools use VALUE, not the TYPE tag', () {
      // VRChat tags every bool "T" - the old code read that as always-on.
      expect(OscQueryClient.valueFromNode({'TYPE': 'T', 'VALUE': [false]}), false);
      expect(OscQueryClient.valueFromNode({'TYPE': 'T', 'VALUE': [true]}), true);
      expect(OscQueryClient.valueFromNode({'TYPE': 'F'}), false);
      expect(OscQueryClient.valueFromNode({'TYPE': 'f', 'VALUE': [0.25]}), 0.25);
      expect(OscQueryClient.valueFromNode({'TYPE': 'i', 'VALUE': [3]}), 3.0);
      expect(OscQueryClient.valueFromNode({'TYPE': 's', 'VALUE': ['x']}), isNull);
    });
  });

  group('VRChat avatar config files', () {
    test('BOM is tolerated and parameters are typed', () {
      const json = '{"id":"avtr_x","name":"Test Avatar","parameters":['
          '{"name":"Ears","input":{"address":"/avatar/parameters/Ears","type":"Bool"},'
          '"output":{"address":"/avatar/parameters/Ears","type":"Bool"}},'
          '{"name":"Hue","input":{"address":"/avatar/parameters/Hue","type":"Float"}},'
          '{"name":"Outfit","input":{"address":"/avatar/parameters/Outfit","type":"Int"}},'
          '{"name":"IsLocal","output":{"address":"/avatar/parameters/IsLocal","type":"Bool"}}]}';
      final decoded = VrchatFiles.decodeAvatarConfig([0xEF, 0xBB, 0xBF, ...json.codeUnits])!;
      expect(decoded['name'], 'Test Avatar');
      final params = VrchatFiles.parametersFromConfig(decoded);
      expect(params.map((p) => p.name), ['Ears', 'Hue', 'IsLocal', 'Outfit']);
      expect(params.firstWhere((p) => p.name == 'Outfit').kind, DiscoveredKind.int);
      expect(params.firstWhere((p) => p.name == 'IsLocal').readOnly, true);
      expect(params.firstWhere((p) => p.name == 'Ears').readOnly, false);
    });
  });
}
