import 'dart:io';

import 'config_store.dart';

/// appends crash/error details to %APPDATA%\OSCSlider\crash.log - the app
/// has no console when launched normally, so this is the only trace left
/// behind if something crashes instead of showing a dialog.
class CrashLog {
  static Future<void> record(Object error, StackTrace? stack, {String? context}) async {
    try {
      final file = File('${File(ConfigStore.path).parent.path}${Platform.pathSeparator}crash.log');
      final entry = StringBuffer()
        ..writeln('--- ${DateTime.now().toIso8601String()}${context != null ? ' [$context]' : ''} ---')
        ..writeln(error.toString())
        ..writeln(stack?.toString() ?? '(no stack trace)')
        ..writeln();
      await file.writeAsString(entry.toString(), mode: FileMode.append);
    } catch (_) {
      // logging must never itself throw - nothing more we can do here.
    }
  }
}
