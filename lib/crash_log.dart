import 'dart:io';

import 'config_store.dart';

/// appends crash/error details to %APPDATA%\OSCSlider\crash.log - the app
/// has no console when launched normally, so this is the only trace left
/// behind if something crashes instead of showing a dialog.
class CrashLog {
  // the same failure repeating every tick (a bad host, a dead network)
  // would otherwise append thousands of identical entries a minute.
  static const _repeatWindow = Duration(seconds: 30);
  static const _maxBytes = 1024 * 1024;
  static final Map<String, DateTime> _lastLogged = {};
  static final Map<String, int> _suppressed = {};
  static Future<void> _pending = Future.value();

  static String get path => '${File(ConfigStore.path).parent.path}${Platform.pathSeparator}crash.log';

  static Future<void> record(Object error, StackTrace? stack, {String? context}) {
    final key = '${context ?? ''}|${error.runtimeType}|${error.toString().split('\n').first}';
    final now = DateTime.now();
    final last = _lastLogged[key];
    if (last != null && now.difference(last) < _repeatWindow) {
      _suppressed[key] = (_suppressed[key] ?? 0) + 1;
      return _pending;
    }
    _lastLogged[key] = now;
    final skipped = _suppressed.remove(key) ?? 0;
    if (_lastLogged.length > 200) _lastLogged.clear();

    final entry = StringBuffer()
      ..writeln('--- ${now.toIso8601String()}${context != null ? ' [$context]' : ''} ---')
      ..writeln(error.toString());
    if (skipped > 0) entry.writeln('(same error repeated $skipped more times since the last entry)');
    entry
      ..writeln(stack?.toString() ?? '(no stack trace)')
      ..writeln();

    // chained so concurrent records never interleave inside the file.
    return _pending = _pending.then((_) => _write(entry.toString()));
  }

  static Future<void> _write(String entry) async {
    try {
      final file = File(path);
      if (await file.exists() && await file.length() > _maxBytes) {
        // keep one previous generation around instead of growing forever.
        await file.rename('$path.old');
      }
      await File(path).writeAsString(entry, mode: FileMode.append, flush: true);
    } catch (_) {
      // logging must never itself throw - nothing more we can do here.
    }
  }
}
