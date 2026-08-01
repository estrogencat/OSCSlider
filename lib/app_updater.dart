import 'dart:convert';
import 'dart:io';

const _repoApiLatestRelease = 'https://api.github.com/repos/estrogencat/OSCSlider/releases/latest';

class UpdateInfo {
  final String version;
  final String url;
  UpdateInfo(this.version, this.url);
}

/// checks GitHub's "latest release" endpoint (excludes pre-releases/drafts
/// by definition). null means no update *or* check failed - fine for a
/// silent caller.
Future<UpdateInfo?> checkForUpdate(String currentVersion) async {
  final client = HttpClient();
  try {
    final request = await client.getUrl(Uri.parse(_repoApiLatestRelease));
    // GitHub's API rejects requests with no User-Agent header.
    request.headers.set('User-Agent', 'OSCSlider-updater');
    request.headers.set('Accept', 'application/vnd.github+json');
    final response = await request.close().timeout(const Duration(seconds: 10));
    if (response.statusCode != 200) return null;

    final body = await response.transform(utf8.decoder).join();
    final json = jsonDecode(body) as Map<String, dynamic>;
    final tag = json['tag_name'] as String?;
    final url = json['html_url'] as String?;
    if (tag == null || url == null) return null;

    final latest = tag.startsWith('v') ? tag.substring(1) : tag;
    if (_compareVersions(latest, currentVersion) <= 0) return null;
    return UpdateInfo(latest, url);
  } catch (_) {
    return null;
  } finally {
    client.close();
  }
}

// compares "x.y.z"-style versions (ignoring any trailing "-something"/
// "+something" metadata); returns >0 if a is newer than b.
int _compareVersions(String a, String b) {
  List<int> parts(String v) => v.split(RegExp(r'[-+]')).first.split('.').map((p) => int.tryParse(p) ?? 0).toList();
  final pa = parts(a);
  final pb = parts(b);
  for (var i = 0; i < 3; i++) {
    final va = i < pa.length ? pa[i] : 0;
    final vb = i < pb.length ? pb[i] : 0;
    if (va != vb) return va - vb;
  }
  return 0;
}
