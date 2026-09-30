import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:osc_slider/discovery_flow.dart';
import 'package:osc_slider/mdns_codec.dart';
import 'package:osc_slider/osc_client.dart';
import 'package:osc_slider/osc_input_hub.dart';
import 'package:osc_slider/oscquery_client.dart';
import 'package:osc_slider/oscquery_service.dart';

/// a stand-in for VRChat's own OSCQuery server, shaped like the real tree.
Map<String, Object?> _vrchatTree() => {
      'FULL_PATH': '/',
      'ACCESS': 0,
      'CONTENTS': {
        'avatar': {
          'FULL_PATH': '/avatar',
          'ACCESS': 0,
          'CONTENTS': {
            'change': {'FULL_PATH': '/avatar/change', 'ACCESS': 3, 'TYPE': 's', 'VALUE': ['avtr_test']},
            'parameters': {
              'FULL_PATH': '/avatar/parameters',
              'ACCESS': 0,
              'CONTENTS': {
                'Ears': {'FULL_PATH': '/avatar/parameters/Ears', 'ACCESS': 3, 'TYPE': 'T', 'VALUE': [false]},
                'Hue': {'FULL_PATH': '/avatar/parameters/Hue', 'ACCESS': 3, 'TYPE': 'f', 'VALUE': [0.25]},
                'Outfit': {'FULL_PATH': '/avatar/parameters/Outfit', 'ACCESS': 3, 'TYPE': 'i', 'VALUE': [2]},
                'Grounded': {'FULL_PATH': '/avatar/parameters/Grounded', 'ACCESS': 1, 'TYPE': 'T', 'VALUE': [true]},
                'VF67_Mayu': {
                  'FULL_PATH': '/avatar/parameters/VF67_Mayu',
                  'CONTENTS': {
                    'Purr': {'FULL_PATH': '/avatar/parameters/VF67_Mayu/Purr', 'ACCESS': 3, 'TYPE': 'T', 'VALUE': [true]},
                  },
                },
              },
            },
          },
        },
      },
    };

Map<String, Object?>? _node(String path) {
  Map<String, Object?> node = _vrchatTree();
  for (final seg in path.split('/').where((s) => s.isNotEmpty)) {
    final child = (node['CONTENTS'] as Map?)?[seg];
    if (child is! Map<String, Object?>) return null;
    node = child;
  }
  return node;
}

void main() {
  late HttpServer fakeVrchat;

  setUpAll(() async {
    fakeVrchat = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    fakeVrchat.listen((req) {
      final res = req.response;
      if (req.uri.query.contains('HOST_INFO')) {
        res.write(jsonEncode({'NAME': 'VRChat-Client-TEST', 'OSC_IP': '127.0.0.1', 'OSC_PORT': 9000, 'OSC_TRANSPORT': 'UDP'}));
      } else {
        final node = _node(req.uri.path);
        if (node == null) {
          res.statusCode = 404;
        } else {
          res.write(jsonEncode(node));
        }
      }
      res.close();
    });
    await oscInputHub.start(legacyPort: 49001);
  });

  tearDownAll(() async {
    await oscInputHub.stop();
    await fakeVrchat.close(force: true);
  });

  test('finds VRChat from its mDNS announcement and loads a typed parameter list', () async {
    if (!(oscInputHub.service?.isAdvertising ?? false)) {
      markTestSkipped('mDNS unavailable: ${oscInputHub.service?.error}');
      return;
    }
    const instance = 'VRChat-Client-TEST';
    final socket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
    socket.send(
      encodeDnsMessage(DnsMessage(
        isResponse: true,
        answers: [DnsRecord.ptr(oscJsonServiceType, '$instance.$oscJsonServiceType')],
        additionals: [
          DnsRecord.srv('$instance.$oscJsonServiceType', '$instance.oscjson.local', fakeVrchat.port),
          DnsRecord.a('$instance.oscjson.local', InternetAddress.loopbackIPv4),
        ],
      )),
      InternetAddress.loopbackIPv4,
      mdnsPort,
    );
    socket.close();
    await Future.delayed(const Duration(milliseconds: 200));

    final watch = Stopwatch()..start();
    final result = await loadDiscovery(developerMode: false, timeout: const Duration(seconds: 3));
    expect(watch.elapsed, lessThan(const Duration(seconds: 2)), reason: 'a known VRChat is found without a slow search');
    expect(result.source, DiscoverySource.oscQuery);
    final byName = {for (final p in result.params) p.name: p};
    expect(byName.keys, containsAll(['Ears', 'Hue', 'Outfit', 'Grounded', 'VF67_Mayu/Purr']));
    expect(byName['Ears']!.value, false, reason: 'bools read VALUE, not the "T" type tag');
    expect(byName['Ears']!.kind, DiscoveredKind.bool);
    expect(byName['Outfit']!.kind, DiscoveredKind.int);
    expect(byName['Outfit']!.toControl().max, 255);
    expect(byName['Grounded']!.readOnly, true);
    expect(byName['Hue']!.value, 0.25);

    final endpoint = (await OscQueryClient.findVrchat()).endpoint!;
    expect(endpoint.oscPort, 9000);
    expect(await OscQueryClient.fetchAvatarId(endpoint), 'avtr_test');
    expect(await OscQueryClient.fetchParameterValue(endpoint, '/avatar/parameters/VF67_Mayu/Purr'), true);
    await expectLater(
      OscQueryClient.fetchParameterValue(endpoint, '/avatar/parameters/Missing'),
      throwsA(isA<OscQueryException>().having((e) => e.notFound, 'notFound', true)),
    );
  });

  test('OSC sent to the OSCQuery port reaches the hub', () async {
    final port = oscInputHub.service!.oscPort!;
    final got = oscInputHub.messages.firstWhere((m) => m.address == '/avatar/parameters/Tail');
    final client = OscClient(host: '127.0.0.1', port: port);
    await client.sendFloat('/avatar/parameters/Tail', 0.5);
    final msg = await got.timeout(const Duration(seconds: 3));
    expect(msg.args.single, 0.5);
    expect(oscInputHub.status.value.receiving, true);
    client.dispose();
  });
}
