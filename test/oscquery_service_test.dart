import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:osc_slider/mdns_codec.dart';
import 'package:osc_slider/osc_client.dart';
import 'package:osc_slider/osc_listener.dart';
import 'package:osc_slider/oscquery_service.dart';

Future<Object?> _getJson(int port, String pathAndQuery) async {
  final client = HttpClient();
  try {
    final request = await client.getUrl(Uri.parse('http://127.0.0.1:$port$pathAndQuery'));
    final response = await request.close();
    final body = await response.transform(utf8.decoder).join();
    return response.statusCode == 200 ? jsonDecode(body) : response.statusCode;
  } finally {
    client.close(force: true);
  }
}

void main() {
  late OscQueryService service;
  final packets = <Uint8List>[];

  setUp(() async {
    packets.clear();
    service = OscQueryService(onPacket: packets.add);
    await service.start();
  });

  tearDown(() => service.stop());

  test('serves HOST_INFO pointing at its OSC port', () async {
    final info = await _getJson(service.httpPort!, '/?HOST_INFO') as Map;
    expect(info['OSC_PORT'], service.oscPort);
    expect(info['OSC_IP'], '127.0.0.1');
    expect(info['OSC_TRANSPORT'], 'UDP');
    expect(info['NAME'], service.instanceName);
  });

  test('advertises /avatar/change so VRChat sends to it', () async {
    final root = await _getJson(service.httpPort!, '/') as Map;
    expect(root['CONTENTS']['avatar']['CONTENTS']['change']['FULL_PATH'], '/avatar/change');
    final node = await _getJson(service.httpPort!, '/avatar/change') as Map;
    expect(node['TYPE'], 's');
    expect(await _getJson(service.httpPort!, '/nope'), 404);
  });

  test('receives OSC sent to its port', () async {
    final client = OscClient(host: '127.0.0.1', port: service.oscPort!);
    await client.sendBool('/avatar/parameters/Ears', true);
    for (var i = 0; i < 50 && packets.isEmpty; i++) {
      await Future.delayed(const Duration(milliseconds: 20));
    }
    expect(parseOscMessage(packets.single)!.address, '/avatar/parameters/Ears');
    client.dispose();
  });

  test('answers an mDNS query for its service type', () async {
    if (!service.isAdvertising) {
      markTestSkipped('mDNS port unavailable here: ${service.error}');
      return;
    }
    // a legacy unicast query (source port != 5353) gets a direct reply,
    // which works even where multicast doesn't route.
    final socket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
    final reply = Completer<DnsMessage>();
    // other test files run their own responders on the same machine - wait
    // for the answer from this one.
    socket.listen((e) {
      if (e != RawSocketEvent.read) return;
      final dg = socket.receive();
      final msg = dg == null ? null : decodeDnsMessage(dg.data);
      final ours = msg != null &&
          msg.isResponse &&
          msg.answers.any((r) => r.ptrTarget?.startsWith(service.instanceName) ?? false);
      if (ours && !reply.isCompleted) reply.complete(msg);
    });
    socket.send(
      encodeDnsMessage(const DnsMessage(
        id: 42,
        isResponse: false,
        questions: [DnsQuestion(oscJsonServiceType, DnsType.ptr)],
      )),
      mdnsGroupIPv4,
      mdnsPort,
    );
    final msg = await reply.future.timeout(const Duration(seconds: 5));
    expect(msg.id, 42);
    final ptr = msg.answers.firstWhere((r) => r.type == DnsType.ptr);
    expect(ptr.ptrTarget, '${service.instanceName}.$oscJsonServiceType');
    final srv = msg.additionals.firstWhere((r) => r.type == DnsType.srv);
    expect(srv.srvPort, service.httpPort);
    expect(msg.additionals.any((r) => r.type == DnsType.a && r.address == InternetAddress.loopbackIPv4), true);
    socket.close();
  });

  test('learns about VRChat from its announcements', () async {
    if (!service.isAdvertising) {
      markTestSkipped('mDNS port unavailable here: ${service.error}');
      return;
    }
    const instance = 'VRChat-Client-F00BAR';
    final announce = encodeDnsMessage(DnsMessage(
      isResponse: true,
      answers: [DnsRecord.ptr(oscJsonServiceType, '$instance.$oscJsonServiceType')],
      additionals: [
        DnsRecord.srv('$instance.$oscJsonServiceType', '$instance.oscjson.local', 43210),
        DnsRecord.a('$instance.oscjson.local', InternetAddress.loopbackIPv4),
      ],
    ));
    final socket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
    socket.send(announce, mdnsGroupIPv4, mdnsPort);
    // other test files announce their own fake VRChats on the same network.
    Iterable<OscQueryPeer> mine() => service.peers.where((p) => p.instanceName == instance);
    for (var i = 0; i < 50 && mine().isEmpty; i++) {
      await Future.delayed(const Duration(milliseconds: 20));
    }
    final peer = mine().single;
    expect(peer.isVrchat, true);
    expect(peer.port, 43210);
    expect(peer.host, '127.0.0.1');

    // and forgets it again on a goodbye (TTL 0).
    final goodbye = encodeDnsMessage(DnsMessage(
      isResponse: true,
      answers: [DnsRecord.ptr(oscJsonServiceType, '$instance.$oscJsonServiceType', ttl: 0)],
    ));
    socket.send(goodbye, mdnsGroupIPv4, mdnsPort);
    for (var i = 0; i < 50 && mine().isNotEmpty; i++) {
      await Future.delayed(const Duration(milliseconds: 20));
    }
    expect(mine(), isEmpty);
    socket.close();
  });
}
