import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import 'crash_log.dart';
import 'param_control.dart';

const _defaultConfigContents = '''
{
  "host": "127.0.0.1",
  "port": 9000,
  "parameters": [
    {
      "name": "ExampleRadial",
      "label": "Example Radial",
      "type": "slider",
      "min": 0.0,
      "max": 1.0,
      "default": 0.0
    },
    {
      "name": "ExampleToggle",
      "label": "Example Toggle",
      "type": "toggle",
      "default": false
    }
  ]
}
''';

class ConfigLoadException implements Exception {
  final String message;
  final bool backupAvailable;
  ConfigLoadException(this.message, {required this.backupAvailable});
  @override
  String toString() => message;
}

class ConfigStore {
  static String get _sep => Platform.pathSeparator;

  // %APPDATA%\OSCSlider\config.json - a Program Files install isn't
  // user-writable without elevation, so config can't live next to the exe.
  /// tests point this at a temp dir so they never touch the real config.
  @visibleForTesting
  static String? directoryOverride;

  static Directory _configDir() {
    final override = directoryOverride;
    if (override != null) return Directory(override);
    final appData = Platform.environment['APPDATA'];
    final base = appData ?? Directory.systemTemp.path;
    return Directory('$base${_sep}OSCSlider');
  }

  static File _configFile() => File('${_configDir().path}${_sep}config.json');
  static File _backupFile() => File('${_configDir().path}${_sep}config.json.bak');
  static File _tempFile() => File('${_configDir().path}${_sep}config.json.tmp');

  // config.json used to live next to the exe - if someone's upgrading from
  // that version and hasn't got a config in the new location yet, bring
  // their old one along instead of silently resetting them to defaults.
  static File _legacyConfigFile() {
    final exeDir = File(Platform.resolvedExecutable).parent;
    return File('${exeDir.path}${_sep}config.json');
  }

  static String get path => _configFile().path;
  static String get directory => _configDir().path;

  /// set when the most recent save failed, cleared by the next good one -
  /// shown as a banner so a failing disk/permission issue isn't invisible.
  static final ValueNotifier<String?> lastSaveError = ValueNotifier(null);

  static AppConfig _decode(String contents) {
    // Notepad and friends like to prepend a byte order mark.
    if (contents.startsWith('﻿')) contents = contents.substring(1);
    if (contents.trim().isEmpty) throw const FormatException('config.json is empty');
    final json = jsonDecode(contents);
    if (json is! Map<String, dynamic>) throw const FormatException('config.json is not a JSON object');
    return AppConfig.fromJson(json);
  }

  static Future<AppConfig> load() async {
    final dir = _configDir();
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }

    final file = _configFile();
    if (!await file.exists()) {
      final temp = _tempFile();
      final legacy = _legacyConfigFile();
      if (await temp.exists()) {
        // a crash landed between writing the new copy and swapping it in.
        await temp.rename(file.path);
      } else if (await legacy.exists()) {
        await legacy.copy(file.path);
      } else {
        await file.writeAsString(_defaultConfigContents);
      }
    }

    final String contents;
    final AppConfig config;
    try {
      contents = await file.readAsString();
      config = _decode(contents);
    } catch (e) {
      throw ConfigLoadException(e.toString(), backupAvailable: await _backupFile().exists());
    }
    // the last copy known to load cleanly - what "Restore backup" goes back to.
    try {
      await _backupFile().writeAsString(contents, flush: true);
    } catch (_) {}
    return config;
  }

  /// replaces a broken config.json with the backup from the last good launch.
  static Future<AppConfig> restoreBackup() async {
    final backup = _backupFile();
    final config = _decode(await backup.readAsString());
    await _setAside();
    await backup.copy(_configFile().path);
    return config;
  }

  /// moves a broken config.json out of the way (kept, not deleted) and
  /// starts over with defaults.
  static Future<AppConfig> startFresh() async {
    await _setAside();
    await _configFile().writeAsString(_defaultConfigContents);
    return _decode(_defaultConfigContents);
  }

  static Future<void> _setAside() async {
    final file = _configFile();
    if (!await file.exists()) return;
    final stamp = DateTime.now().toIso8601String().replaceAll(':', '-').split('.').first;
    await file.rename('${_configDir().path}${_sep}config.broken-$stamp.json');
  }

  static Future<void> _chain = Future.value();
  static int _requested = 0;
  static int _written = 0;
  static AppConfig? _latest;

  /// saves are serialized and coalesced: a burst of saves while one is
  /// being written collapses into a single follow-up write of the latest
  /// state. each write goes to a temp file first and is then swapped in, so
  /// a crash or power cut mid-save can't leave a half-written config.json
  /// behind (which used to brick the next launch).
  static Future<void> save(AppConfig config) {
    _latest = config;
    final ticket = ++_requested;
    return _chain = _chain.then((_) async {
      if (_written >= ticket) return;
      final covers = _requested;
      final latest = _latest;
      if (latest == null) return;
      try {
        const encoder = JsonEncoder.withIndent('  ');
        await _writeAtomic(encoder.convert(latest.toJson()));
        _written = covers;
        if (lastSaveError.value != null) lastSaveError.value = null;
      } catch (e, st) {
        lastSaveError.value = e.toString();
        await CrashLog.record(e, st, context: 'ConfigStore.save');
      }
    });
  }

  /// waits for any queued save to land - call before the app exits.
  static Future<void> flush() => _chain;

  static Future<void> _writeAtomic(String contents) async {
    final dir = _configDir();
    if (!await dir.exists()) await dir.create(recursive: true);
    final temp = _tempFile();
    await temp.writeAsString(contents, flush: true);
    // antivirus/cloud-sync tools can briefly lock the target on Windows.
    for (var attempt = 0;; attempt++) {
      try {
        await temp.rename(_configFile().path);
        return;
      } on FileSystemException {
        if (attempt >= 4) {
          // last resort: write in place rather than lose the save entirely.
          await _configFile().writeAsString(contents, flush: true);
          try {
            await temp.delete();
          } catch (_) {}
          return;
        }
        await Future.delayed(Duration(milliseconds: 50 * (attempt + 1)));
      }
    }
  }
}
