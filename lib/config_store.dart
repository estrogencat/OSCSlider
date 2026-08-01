import 'dart:convert';
import 'dart:io';

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

class ConfigStore {
  // %APPDATA%\OSCSlider\config.json - a Program Files install isn't
  // user-writable without elevation, so config can't live next to the exe.
  static Directory _configDir() {
    final appData = Platform.environment['APPDATA'];
    final base = appData ?? Directory.systemTemp.path;
    return Directory('$base${Platform.pathSeparator}OSCSlider');
  }

  static File _configFile() {
    return File('${_configDir().path}${Platform.pathSeparator}config.json');
  }

  // config.json used to live next to the exe - if someone's upgrading from
  // that version and hasn't got a config in the new location yet, bring
  // their old one along instead of silently resetting them to defaults.
  static File _legacyConfigFile() {
    final exeDir = File(Platform.resolvedExecutable).parent;
    return File('${exeDir.path}${Platform.pathSeparator}config.json');
  }

  static Future<AppConfig> load() async {
    final dir = _configDir();
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }

    final file = _configFile();
    if (!await file.exists()) {
      final legacy = _legacyConfigFile();
      if (await legacy.exists()) {
        await legacy.copy(file.path);
      } else {
        await file.writeAsString(_defaultConfigContents);
      }
    }

    final contents = await file.readAsString();
    final json = jsonDecode(contents) as Map<String, dynamic>;
    return AppConfig.fromJson(json);
  }

  static Future<void> save(AppConfig config) async {
    final file = _configFile();
    const encoder = JsonEncoder.withIndent('  ');
    await file.writeAsString(encoder.convert(config.toJson()));
  }

  static String get path => _configFile().path;
}
