import 'dart:io';

/// where things live on each OS - kept in one place so the rest of the app
/// doesn't need to know which one it's running on.
class PlatformPaths {
  static String get _sep => Platform.pathSeparator;
  static String? _env(String key) {
    final v = Platform.environment[key];
    return v == null || v.isEmpty ? null : v;
  }

  static String? get home => _env('HOME') ?? _env('USERPROFILE');

  static bool get isMobile => Platform.isAndroid || Platform.isIOS;

  /// the app's private storage on Android, looked up once at startup
  /// (see AndroidPlatform.init) since there's no environment variable for it.
  static String? androidFilesDir;

  /// the app's own settings folder:
  /// - Windows: %APPDATA%\OSCSlider (a Program Files install isn't writable)
  /// - macOS: ~/Library/Application Support/OSCSlider (inside the sandbox
  ///   container when sandboxed, which HOME already points into)
  /// - Linux: $XDG_CONFIG_HOME/OSCSlider, else ~/.config/OSCSlider
  static Directory configDir() {
    String? base;
    if (Platform.isAndroid) {
      base = androidFilesDir;
    } else if (Platform.isWindows) {
      base = _env('APPDATA');
    } else if (Platform.isMacOS) {
      final h = home;
      if (h != null) base = '$h/Library/Application Support';
    } else {
      base = _env('XDG_CONFIG_HOME') ?? (home != null ? '$home/.config' : null);
    }
    return Directory('${base ?? Directory.systemTemp.path}${_sep}OSCSlider');
  }

  /// the user's Downloads folder (XDG_DOWNLOAD_DIR on Linux), else temp.
  static Directory downloadsDir() {
    final h = home;
    if (h == null) return Directory.systemTemp;
    if (Platform.isLinux) {
      try {
        final dirs = File('${_env('XDG_CONFIG_HOME') ?? '$h/.config'}/user-dirs.dirs').readAsStringSync();
        final m = RegExp(r'^XDG_DOWNLOAD_DIR="(.+)"', multiLine: true).firstMatch(dirs);
        if (m != null) {
          final dir = Directory(m.group(1)!.replaceFirst(r'$HOME', h));
          if (dir.existsSync()) return dir;
        }
      } catch (_) {}
    }
    final dir = Directory('$h${_sep}Downloads');
    return dir.existsSync() ? dir : Directory.systemTemp;
  }

  /// SO_REUSEPORT - unsupported on Windows (reuseAddress is what shares a
  /// port there), but needed on Linux/macOS to share UDP 5353 with avahi or
  /// mDNSResponder, which set it on their own sockets.
  static bool get canReusePort => !Platform.isWindows;

  /// every folder VRChat might keep its per-avatar OSC configs in. on Linux
  /// VRChat runs under Proton, so its "LocalLow" lives inside a Steam
  /// compatdata prefix, in whichever Steam library it's installed to.
  static List<Directory> vrchatOscRoots() {
    if (isMobile) return const [];
    const tail = ['AppData', 'LocalLow', 'VRChat', 'VRChat', 'OSC'];
    if (Platform.isWindows) {
      final local = _env('LOCALAPPDATA');
      final profile = _env('USERPROFILE');
      return [
        // LocalLow is a sibling of Local under AppData, not nested inside it.
        if (local != null) Directory('${Directory(local).parent.path}\\LocalLow\\VRChat\\VRChat\\OSC'),
        if (profile != null) Directory('$profile\\${tail.join('\\')}'),
      ];
    }
    final h = home;
    if (h == null || Platform.isMacOS) return const [];
    final steamRoots = {
      '$h/.steam/steam',
      '$h/.steam/root',
      '$h/.local/share/Steam',
      '$h/.var/app/com.valvesoftware.Steam/.local/share/Steam',
      '$h/snap/steam/common/.local/share/Steam',
    };
    final libraries = <String>{...steamRoots};
    for (final root in steamRoots) {
      libraries.addAll(_steamLibraries('$root/steamapps/libraryfolders.vdf'));
    }
    final seen = <String>{};
    final out = <Directory>[];
    for (final lib in libraries) {
      final dir = Directory('$lib/steamapps/compatdata/438100/pfx/drive_c/users/steamuser/${tail.join('/')}');
      String key;
      try {
        key = dir.existsSync() ? dir.resolveSymbolicLinksSync() : dir.path;
      } catch (_) {
        key = dir.path;
      }
      if (seen.add(key)) out.add(dir);
    }
    return out;
  }

  // libraryfolders.vdf lists every Steam library as `"path"  "/some/dir"`.
  static List<String> _steamLibraries(String vdfPath) {
    try {
      final file = File(vdfPath);
      if (!file.existsSync()) return const [];
      return RegExp(r'"path"\s+"([^"]+)"')
          .allMatches(file.readAsStringSync())
          .map((m) => m.group(1)!.replaceAll(r'\\', '\\'))
          .toList();
    } catch (_) {
      return const [];
    }
  }
}
