import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:package_info_plus/package_info_plus.dart';

import 'platform_paths.dart';

const _releasesApi = 'https://api.github.com/repos/estrogencat/OSCSlider/releases?per_page=20';
const releasesPageUrl = 'https://github.com/estrogencat/OSCSlider/releases';

// set by the release workflow. the platform version is numeric only, so
// without this a beta build couldn't tell itself apart from the final.
const _buildVersion = String.fromEnvironment('OSCSLIDER_VERSION');

Future<String> currentAppVersion() async {
  if (_buildVersion.isNotEmpty) return _buildVersion;
  return (await PackageInfo.fromPlatform()).version;
}

/// dev/test builds from workflow_dispatch - they'd always look outdated.
bool isDevVersion(String version) => version.contains('-dev');

class UpdateException implements Exception {
  final String message;
  UpdateException(this.message);
  @override
  String toString() => message;
}

class ReleaseAsset {
  final String name;
  final Uri url;
  final int size;
  const ReleaseAsset(this.name, this.url, this.size);
}

class UpdateInfo {
  final String version;
  final String notes;
  final Uri pageUrl;
  final bool prerelease;
  final DateTime? publishedAt;
  final List<ReleaseAsset> assets;
  const UpdateInfo({
    required this.version,
    required this.notes,
    required this.pageUrl,
    this.prerelease = false,
    this.publishedAt,
    this.assets = const [],
  });
}

/// how this copy was installed, which decides how it can update itself.
enum InstallKind { windowsInstaller, windowsPortable, appImage, deb, linuxPortable, macos, android, unknown }

InstallKind detectInstallKind() {
  if (Platform.isAndroid) return InstallKind.android;
  try {
    final exeDir = File(Platform.resolvedExecutable).parent.path;
    if (Platform.isWindows) {
      // Inno Setup leaves its uninstaller next to the exe.
      return File('$exeDir\\unins000.exe').existsSync() ? InstallKind.windowsInstaller : InstallKind.windowsPortable;
    }
    if (Platform.isLinux) {
      final appImage = Platform.environment['APPIMAGE'];
      if (appImage != null && appImage.isNotEmpty) return InstallKind.appImage;
      return exeDir.startsWith('/opt/oscslider') ? InstallKind.deb : InstallKind.linuxPortable;
    }
    if (Platform.isMacOS) return InstallKind.macos;
  } catch (_) {}
  return InstallKind.unknown;
}

/// true when the update replaces this copy and restarts it; otherwise it's
/// downloaded and handed to the OS (or shown in the folder) to finish.
bool updatesInPlace(InstallKind kind) => kind == InstallKind.windowsInstaller || kind == InstallKind.appImage;

ReleaseAsset? assetFor(UpdateInfo info, InstallKind kind) {
  bool Function(String) match = switch (kind) {
    InstallKind.windowsInstaller => (n) => n == 'OSCSlider-Setup.exe',
    InstallKind.windowsPortable => (n) => n.startsWith('OSCSlider-windows') && n.endsWith('.zip'),
    InstallKind.appImage => (n) => n.endsWith('.AppImage'),
    InstallKind.deb => (n) => n.endsWith('_amd64.deb'),
    InstallKind.linuxPortable => (n) => n.startsWith('OSCSlider-linux') && n.endsWith('.tar.gz'),
    InstallKind.macos => (n) => n.endsWith('.dmg'),
    InstallKind.android => (n) => n.endsWith('.apk'),
    InstallKind.unknown => (_) => false,
  };
  for (final a in info.assets) {
    if (match(a.name)) return a;
  }
  return null;
}

HttpClient _client() => HttpClient()
  ..connectionTimeout = const Duration(seconds: 10)
  ..findProxy = HttpClient.findProxyFromEnvironment
  ..userAgent = 'OSCSlider-updater';

/// the newest release above [currentVersion], or null when up to date.
/// throws [UpdateException] when the check itself fails.
Future<UpdateInfo?> checkForUpdate(String currentVersion, {bool includePrereleases = false}) async {
  final client = _client();
  try {
    final request = await client.getUrl(Uri.parse(_releasesApi));
    request.headers.set('Accept', 'application/vnd.github+json');
    final response = await request.close().timeout(const Duration(seconds: 15));
    final body = await response.transform(utf8.decoder).join().timeout(const Duration(seconds: 15));
    if (response.statusCode == 403 || response.statusCode == 429) {
      throw UpdateException('GitHub is rate-limiting update checks right now, try again in a bit');
    }
    if (response.statusCode != 200) throw UpdateException('GitHub answered ${response.statusCode}');
    final json = jsonDecode(body);
    if (json is! List) throw UpdateException('unexpected reply from GitHub');
    return pickUpdate(json, currentVersion, includePrereleases: includePrereleases);
  } on UpdateException {
    rethrow;
  } on TimeoutException {
    throw UpdateException('GitHub took too long to answer');
  } on SocketException catch (e) {
    throw UpdateException('couldn\'t reach GitHub (${e.osError?.message ?? e.message})');
  } catch (e) {
    throw UpdateException('update check failed: $e');
  } finally {
    client.close(force: true);
  }
}

/// picks the newest usable release from GitHub's release list.
UpdateInfo? pickUpdate(List<dynamic> releases, String currentVersion, {bool includePrereleases = false}) {
  UpdateInfo? best;
  for (final r in releases.whereType<Map<String, dynamic>>()) {
    if (r['draft'] == true) continue;
    final prerelease = r['prerelease'] == true;
    if (prerelease && !includePrereleases) continue;
    final tag = r['tag_name'];
    final page = r['html_url'];
    if (tag is! String || page is! String || !RegExp(r'^v?\d+\.\d+').hasMatch(tag)) continue;
    final version = tag.startsWith('v') ? tag.substring(1) : tag;
    if (compareVersions(version, currentVersion) <= 0) continue;
    if (best != null && compareVersions(version, best.version) <= 0) continue;
    best = UpdateInfo(
      version: version,
      notes: (r['body'] as String?) ?? '',
      pageUrl: Uri.parse(page),
      prerelease: prerelease,
      publishedAt: DateTime.tryParse((r['published_at'] as String?) ?? ''),
      assets: [
        for (final a in ((r['assets'] as List?) ?? const []).whereType<Map<String, dynamic>>())
          if (a['name'] is String && a['browser_download_url'] is String)
            ReleaseAsset(
              a['name'] as String,
              Uri.parse(a['browser_download_url'] as String),
              (a['size'] as num?)?.toInt() ?? 0,
            ),
      ],
    );
  }
  return best;
}

/// semver-style comparison, >0 when [a] is newer. a pre-release sorts
/// below its final ("2.1.0-beta.2" < "2.1.0"), and build metadata is ignored.
int compareVersions(String a, String b) {
  (List<int>, List<String>) parse(String v) {
    v = v.trim();
    if (v.startsWith('v')) v = v.substring(1);
    final plus = v.indexOf('+');
    if (plus != -1) v = v.substring(0, plus);
    final dash = v.indexOf('-');
    final core = dash == -1 ? v : v.substring(0, dash);
    final pre = dash == -1 ? <String>[] : v.substring(dash + 1).split('.');
    return (core.split('.').map((p) => int.tryParse(p) ?? 0).toList(), pre);
  }

  final (ca, pa) = parse(a);
  final (cb, pb) = parse(b);
  for (var i = 0; i < 3; i++) {
    final va = i < ca.length ? ca[i] : 0;
    final vb = i < cb.length ? cb[i] : 0;
    if (va != vb) return va - vb;
  }
  if (pa.isEmpty || pb.isEmpty) return pa.isEmpty && pb.isEmpty ? 0 : (pa.isEmpty ? 1 : -1);
  for (var i = 0; i < pa.length && i < pb.length; i++) {
    final na = int.tryParse(pa[i]);
    final nb = int.tryParse(pb[i]);
    final c = na != null && nb != null
        ? na - nb
        : na != null
        ? -1
        : nb != null
        ? 1
        : pa[i].compareTo(pb[i]);
    if (c != 0) return c;
  }
  return pa.length - pb.length;
}

/// lets the UI stop a download part-way.
class UpdateCancelToken {
  bool cancelled = false;
}

/// downloads [asset] and checks it against the release's SHA256SUMS.txt.
Future<File> downloadUpdate(
  UpdateInfo info,
  ReleaseAsset asset,
  InstallKind kind, {
  void Function(int received, int total)? onProgress,
  UpdateCancelToken? cancel,
}) async {
  final dest = _downloadTarget(asset, kind, info.version);
  final part = File('${dest.path}.part');
  final client = _client();
  try {
    await dest.parent.create(recursive: true);
    final expected = await _expectedHash(client, info, asset, cancel);
    final digest = await _retrying(asset.name, cancel, () async {
      final response = await _get(client, asset.url, asset.name, const Duration(seconds: 20));
      final total = response.contentLength > 0 ? response.contentLength : asset.size;
      final sink = part.openWrite();
      final hashSink = _DigestSink();
      final hasher = sha256.startChunkedConversion(hashSink);
      var received = 0;
      try {
        await for (final chunk in response.timeout(const Duration(seconds: 30))) {
          if (cancel?.cancelled ?? false) throw UpdateException('download cancelled');
          sink.add(chunk);
          hasher.add(chunk);
          received += chunk.length;
          onProgress?.call(received, total);
        }
      } finally {
        await sink.close();
      }
      hasher.close();
      if (total > 0 && received != total) throw const _Transient('the download was cut off');
      return hashSink.value.toString();
    });
    if (expected != null && digest != expected) {
      throw UpdateException('the download didn\'t match its checksum, so it wasn\'t used');
    }
    if (dest.existsSync()) dest.deleteSync();
    return part.renameSync(dest.path);
  } on UpdateException {
    _tryDelete(part);
    rethrow;
  } catch (e) {
    _tryDelete(part);
    throw UpdateException('download failed: $e');
  } finally {
    client.close(force: true);
  }
}

/// a failure that's usually gone a moment later: a 5xx from GitHub's file
/// servers, a dropped connection, a stall.
class _Transient implements Exception {
  final String reason;
  const _Transient(this.reason);
}

/// pauses between download retries (tests shorten them).
List<Duration> updateRetryPauses = const [Duration(seconds: 1), Duration(seconds: 3), Duration(seconds: 6)];

// runs [attempt], retrying transient failures with a growing pause.
Future<T> _retrying<T>(String what, UpdateCancelToken? cancel, Future<T> Function() attempt) async {
  final pauses = updateRetryPauses;
  for (var i = 0;; i++) {
    String reason;
    try {
      return await attempt();
    } on _Transient catch (e) {
      reason = e.reason;
    } on SocketException catch (e) {
      reason = 'connection problem: ${e.osError?.message ?? e.message}';
    } on HttpException catch (e) {
      reason = 'connection problem: ${e.message}';
    } on TimeoutException {
      reason = 'it stalled';
    }
    if (cancel?.cancelled ?? false) throw UpdateException('download cancelled');
    if (i >= pauses.length) {
      throw UpdateException('GitHub had trouble sending $what ($reason). Try again in a minute, or use the release page.');
    }
    await Future.delayed(pauses[i]);
  }
}

// a 200 response, or a _Transient / UpdateException saying why not.
Future<HttpClientResponse> _get(HttpClient client, Uri url, String what, Duration timeout) async {
  final response = await (await client.getUrl(url)).close().timeout(timeout);
  final code = response.statusCode;
  if (code == 200) return response;
  await response.drain<void>().catchError((_) {});
  if (code >= 500 || code == 429 || code == 408) throw _Transient('HTTP $code');
  throw UpdateException('couldn\'t download $what (HTTP $code)');
}

File _downloadTarget(ReleaseAsset asset, InstallKind kind, String version) {
  final sep = Platform.pathSeparator;
  if (kind == InstallKind.windowsInstaller) {
    return File('${Directory.systemTemp.path}${sep}OSCSlider-update${sep}OSCSlider-Setup-$version.exe');
  }
  if (kind == InstallKind.appImage) {
    // next to the running AppImage, so the final rename stays on one disk.
    final current = File(Platform.environment['APPIMAGE']!);
    if (_writable(current.parent)) return File('${current.path}.new');
  }
  return File('${PlatformPaths.downloadsDir().path}$sep${asset.name}');
}

bool _writable(Directory dir) {
  try {
    final probe = File('${dir.path}${Platform.pathSeparator}.oscslider-write-test');
    probe.writeAsStringSync('');
    probe.deleteSync();
    return true;
  } catch (_) {
    return false;
  }
}

void _tryDelete(File f) {
  try {
    if (f.existsSync()) f.deleteSync();
  } catch (_) {}
}

// null when the release has no checksum list (older releases).
Future<String?> _expectedHash(HttpClient client, UpdateInfo info, ReleaseAsset asset, UpdateCancelToken? cancel) async {
  final sums = info.assets.where((a) => a.name == 'SHA256SUMS.txt').firstOrNull;
  if (sums == null) return null;
  final text = await _retrying(sums.name, cancel, () async {
    final response = await _get(client, sums.url, sums.name, const Duration(seconds: 15));
    return response.transform(utf8.decoder).join().timeout(const Duration(seconds: 15));
  });
  for (final line in const LineSplitter().convert(text)) {
    final m = RegExp(r'^([0-9a-fA-F]{64})\s+\*?(.+)$').firstMatch(line.trim());
    if (m != null && m.group(2) == asset.name) return m.group(1)!.toLowerCase();
  }
  throw UpdateException('${asset.name} isn\'t in the release\'s checksum list');
}

class _DigestSink implements Sink<Digest> {
  Digest? _value;
  Digest get value => _value!;
  @override
  void add(Digest data) => _value = data;
  @override
  void close() {}
}

/// installs a downloaded update. true means the new version (or its
/// installer) has started, so the caller should save and quit right away.
Future<bool> applyUpdate(InstallKind kind, File file) async {
  switch (kind) {
    case InstallKind.windowsInstaller:
      // silent keeps the previous folder and install mode, and the
      // installer relaunches the app when it's done.
      await Process.start(file.path, [
        '/SILENT',
        '/SP-',
        '/NOCANCEL',
        '/NORESTART',
        '/CLOSEAPPLICATIONS',
      ], mode: ProcessStartMode.detached);
      return true;
    case InstallKind.appImage:
      final target = Platform.environment['APPIMAGE']!;
      if (file.path != '$target.new') {
        // couldn't write next to it - leave the download for the user.
        await revealFile(file);
        return false;
      }
      await Process.run('chmod', ['+x', file.path]);
      file.renameSync(target);
      await Process.start(target, const [], mode: ProcessStartMode.detached);
      return true;
    case InstallKind.deb || InstallKind.macos:
      // the software centre opens a .deb, and a .dmg mounts with the drag-to-Applications window.
      await Process.start(Platform.isMacOS ? 'open' : 'xdg-open', [file.path], mode: ProcessStartMode.detached);
      return false;
    default:
      await revealFile(file);
      return false;
  }
}

/// shows [file] in the system file manager.
Future<void> revealFile(File file) async {
  if (Platform.isWindows) {
    await Process.start('explorer.exe', ['/select,', file.path], mode: ProcessStartMode.detached);
  } else if (Platform.isMacOS) {
    await Process.start('open', ['-R', file.path], mode: ProcessStartMode.detached);
  } else {
    await Process.start('xdg-open', [file.parent.path], mode: ProcessStartMode.detached);
  }
}
