import 'dart:convert';
import 'dart:io';

import 'oscquery_client.dart';
import 'platform_paths.dart';

/// reads the per-avatar OSC config files VRChat writes to
/// ...\AppData\LocalLow\VRChat\VRChat\OSC\usr_*\Avatars\avtr_*.json (on
/// Linux, inside VRChat's Proton prefix) - the avatar's display name, and
/// its full parameter list with types, even when VRChat's OSCQuery server
/// is hanging or VRChat isn't running at all.
class VrchatFiles {
  /// the config for [avatarId] - the most recently written one if several
  /// VRChat accounts on this PC have used the same avatar.
  static Future<Map<String, dynamic>?> readAvatarConfig(String avatarId) async {
    try {
      File? newest;
      DateTime? newestTime;
      for (final root in PlatformPaths.vrchatOscRoots()) {
        if (!await root.exists()) continue;
        await for (final userDir in root.list()) {
          if (userDir is! Directory) continue;
          final file = File('${userDir.path}${Platform.pathSeparator}Avatars${Platform.pathSeparator}$avatarId.json');
          if (!await file.exists()) continue;
          final modified = await file.lastModified();
          if (newestTime == null || modified.isAfter(newestTime)) {
            newest = file;
            newestTime = modified;
          }
        }
      }
      if (newest == null) return null;
      return decodeAvatarConfig(await newest.readAsBytes());
    } catch (_) {
      return null;
    }
  }

  /// VRChat writes these with a UTF-8 byte order mark, which jsonDecode
  /// rejects outright - stripped here (this used to make every avatar name
  /// lookup silently fail).
  static Map<String, dynamic>? decodeAvatarConfig(List<int> bytes) {
    var text = utf8.decode(bytes, allowMalformed: true);
    if (text.startsWith('﻿')) text = text.substring(1);
    final json = jsonDecode(text);
    return json is Map<String, dynamic> ? json : null;
  }

  static Future<String?> avatarName(String avatarId) async {
    final json = await readAvatarConfig(avatarId);
    final name = json?['name'];
    return name is String && name.trim().isNotEmpty ? name.trim() : null;
  }

  static Future<List<DiscoveredParam>?> avatarParameters(String avatarId) async {
    final json = await readAvatarConfig(avatarId);
    return json == null ? null : parametersFromConfig(json);
  }

  static List<DiscoveredParam> parametersFromConfig(Map<String, dynamic> json) {
    const root = '/avatar/parameters/';
    final out = <String, DiscoveredParam>{};
    final params = json['parameters'];
    if (params is! List) return const [];
    for (final p in params) {
      if (p is! Map) continue;
      final input = p['input'];
      final output = p['output'];
      final io = input is Map ? input : (output is Map ? output : null);
      if (io == null) continue;
      final address = io['address'];
      if (address is! String || address.isEmpty) continue;
      final name = address.startsWith(root) ? address.substring(root.length) : address;
      final kind = switch ('${io['type']}'.toLowerCase()) {
        'bool' => DiscoveredKind.bool,
        'int' => DiscoveredKind.int,
        'float' => DiscoveredKind.float,
        _ => null,
      };
      if (kind == null) continue;
      // no input block = VRChat won't accept OSC for it (the built-ins).
      out[name] = DiscoveredParam(name, kind, readOnly: input is! Map);
    }
    return out.values.toList()..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
  }
}
