import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:osc_slider/app_updater.dart';
import 'package:osc_slider/param_control.dart';

Map<String, dynamic> _release(
  String tag, {
  bool prerelease = false,
  bool draft = false,
  List<String> assets = const [],
}) => {
  'tag_name': tag,
  'html_url': 'https://example.com/$tag',
  'prerelease': prerelease,
  'draft': draft,
  'body': 'notes for $tag',
  'published_at': '2026-09-30T12:00:00Z',
  'assets': [
    for (final a in assets) {'name': a, 'browser_download_url': 'https://example.com/$a', 'size': 10},
  ],
};

void main() {
  test('compares versions, with pre-releases below their final', () {
    expect(compareVersions('2.0.1', '2.0.0'), greaterThan(0));
    expect(compareVersions('v2.0.0', '2.0.0'), 0);
    expect(compareVersions('2.10.0', '2.9.9'), greaterThan(0));
    expect(compareVersions('2.1.0', '2.1.0-beta.2'), greaterThan(0));
    expect(compareVersions('2.1.0-beta.10', '2.1.0-beta.2'), greaterThan(0));
    expect(compareVersions('2.1.0-rc.1', '2.1.0-beta.9'), greaterThan(0));
    expect(compareVersions('2.1.0-beta', '2.1.0-beta.1'), lessThan(0));
    expect(compareVersions('2.0.0+45', '2.0.0'), 0);
  });

  test('picks the newest release, skipping drafts and (by default) pre-releases', () {
    final releases = [
      _release('v2.2.0-beta.1', prerelease: true),
      _release('v2.3.0', draft: true),
      _release('v2.1.0'),
      _release('v2.0.5'),
      _release('nightly'),
    ];
    expect(pickUpdate(releases, '2.0.0')!.version, '2.1.0');
    expect(pickUpdate(releases, '2.0.0', includePrereleases: true)!.version, '2.2.0-beta.1');
    expect(pickUpdate(releases, '2.1.0'), isNull);
    // a beta user gets the final once it's out.
    expect(pickUpdate([_release('v2.2.0')], '2.2.0-beta.1')!.version, '2.2.0');
  });

  test('matches the right download for each install type', () {
    final info = pickUpdate([
      _release(
        'v9.0.0',
        assets: [
          'OSCSlider-Setup.exe',
          'OSCSlider-windows-x64-portable.zip',
          'OSCSlider-x86_64.AppImage',
          'oscslider_9.0.0_amd64.deb',
          'OSCSlider-linux-x64.tar.gz',
          'OSCSlider-macos.dmg',
          'OSCSlider-macos.zip',
          'OSCSlider-android.apk',
          'SHA256SUMS.txt',
        ],
      ),
    ], '1.0.0')!;
    expect(assetFor(info, InstallKind.windowsInstaller)!.name, 'OSCSlider-Setup.exe');
    expect(assetFor(info, InstallKind.windowsPortable)!.name, 'OSCSlider-windows-x64-portable.zip');
    expect(assetFor(info, InstallKind.appImage)!.name, 'OSCSlider-x86_64.AppImage');
    expect(assetFor(info, InstallKind.deb)!.name, 'oscslider_9.0.0_amd64.deb');
    expect(assetFor(info, InstallKind.linuxPortable)!.name, 'OSCSlider-linux-x64.tar.gz');
    expect(assetFor(info, InstallKind.macos)!.name, 'OSCSlider-macos.dmg');
    expect(assetFor(info, InstallKind.android)!.name, 'OSCSlider-android.apk');
    expect(assetFor(info, InstallKind.unknown), isNull);
  });

  test('update settings survive a save', () {
    final config = AppConfig(host: '127.0.0.1', port: 9000)
      ..checkUpdatesOnStartup = false
      ..includePrereleaseUpdates = true
      ..skippedUpdateVersion = '2.1.0';
    final back = AppConfig.fromJson(jsonDecode(jsonEncode(config.toJson())) as Map<String, dynamic>);
    expect(back.checkUpdatesOnStartup, false);
    expect(back.includePrereleaseUpdates, true);
    expect(back.skippedUpdateVersion, '2.1.0');
    final fresh = AppConfig.fromJson({});
    expect(fresh.checkUpdatesOnStartup, true);
    expect(fresh.skippedUpdateVersion, isNull);
  });

  group('download', () {
    late HttpServer server;
    final payload = utf8.encode('pretend installer ' * 5000);
    var sums = '';

    setUp(() async {
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((req) {
        final body = switch (req.uri.path) {
          '/OSCSlider-Setup.exe' => payload,
          '/SHA256SUMS.txt' => utf8.encode(sums),
          _ => null,
        };
        if (body == null) {
          req.response.statusCode = 404;
        } else {
          req.response.contentLength = body.length;
          req.response.add(body);
        }
        req.response.close();
      });
    });

    tearDown(() => server.close(force: true));

    UpdateInfo info() {
      Uri at(String name) => Uri.parse('http://127.0.0.1:${server.port}/$name');
      return UpdateInfo(
        version: '9.9.9-test',
        notes: '',
        pageUrl: at(''),
        assets: [
          ReleaseAsset('OSCSlider-Setup.exe', at('OSCSlider-Setup.exe'), payload.length),
          ReleaseAsset('SHA256SUMS.txt', at('SHA256SUMS.txt'), 0),
        ],
      );
    }

    test('verifies against SHA256SUMS and reports progress', () async {
      sums = '${sha256.convert(payload)}  OSCSlider-Setup.exe\n';
      final i = info();
      var last = 0;
      final file = await downloadUpdate(
        i,
        i.assets.first,
        InstallKind.windowsInstaller,
        onProgress: (received, total) => last = received,
      );
      expect(file.readAsBytesSync(), payload);
      expect(last, payload.length);
      file.deleteSync();
    });

    test('throws away a download that fails its checksum', () async {
      sums = '${'0' * 64}  OSCSlider-Setup.exe\n';
      final i = info();
      await expectLater(
        downloadUpdate(i, i.assets.first, InstallKind.windowsInstaller),
        throwsA(isA<UpdateException>().having((e) => e.message, 'message', contains('checksum'))),
      );
      final dir = Directory('${Directory.systemTemp.path}${Platform.pathSeparator}OSCSlider-update');
      final leftovers = dir.existsSync() ? dir.listSync().where((f) => f.path.contains('9.9.9-test')) : const [];
      expect(leftovers, isEmpty);
    });
  });
}
