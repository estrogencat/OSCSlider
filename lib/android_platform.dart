import 'dart:io';

import 'package:flutter/services.dart';

import 'crash_log.dart';
import 'platform_paths.dart';

/// the few things Android needs from native code (MainActivity.kt).
class AndroidPlatform {
  static const _channel = MethodChannel('oscslider/platform');

  /// before runApp: where config lives, and letting mDNS through.
  static Future<void> init() async {
    if (!Platform.isAndroid) return;
    try {
      PlatformPaths.androidFilesDir = await _channel.invokeMethod<String>('filesDir');
      await _channel.invokeMethod<bool>('acquireMulticastLock');
    } catch (e, st) {
      await CrashLog.record(e, st, context: 'Android platform setup');
    }
  }

  static Future<void> keepScreenOn(bool on) async {
    if (!Platform.isAndroid) return;
    try {
      await _channel.invokeMethod<bool>('keepScreenOn', on);
    } catch (_) {}
  }
}
