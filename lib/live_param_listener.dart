import 'dart:async';

import 'osc_input_hub.dart';
import 'osc_listener.dart';
import 'oscquery_client.dart';

/// temporary read-only tap on the shared OscInputHub for live
/// /avatar/parameters/* traffic - lets the discover popup's "highlight
/// active parameters" toggle surface a name as soon as it changes.
class LiveParamListener {
  final void Function(String paramName, DiscoveredKind kind) onParamChanged;
  StreamSubscription<OscMessage>? _sub;
  bool _acquired = false;

  LiveParamListener({required this.onParamChanged});

  static const _paramsRoot = '/avatar/parameters/';

  Future<bool> start() async {
    final ok = await oscInputHub.acquire();
    _acquired = true;
    if (!ok) {
      stop();
      return false;
    }
    _sub = oscInputHub.messages.listen((msg) {
      if (!msg.address.startsWith(_paramsRoot) || msg.args.isEmpty) return;
      final name = msg.address.substring(_paramsRoot.length);
      final value = msg.args.first;
      final kind = switch (value) {
        bool() => DiscoveredKind.bool,
        int() => DiscoveredKind.int,
        _ => DiscoveredKind.float,
      };
      onParamChanged(name, kind);
    });
    return true;
  }

  void stop() {
    _sub?.cancel();
    _sub = null;
    if (_acquired) {
      _acquired = false;
      oscInputHub.release();
    }
  }
}

/// tracks which parameters have recently changed while the "highlight active
/// parameters" toggle is on, so they can float to the top - without letting
/// constantly-firing animator/tracking params permanently bury everything else.
///
/// a parameter is treated as noise (and stops being promoted) when either:
/// - it keeps changing at >= [noiseThreshold] changes/sec for most of the
///   last few seconds - sustained, so a quick physbone wiggle that briefly
///   spikes the rate doesn't count, but Voice/Velocity-style chatter does.
/// - it keeps popping back up on its own cycle every few seconds.
class LiveParamTracker {
  List<DiscoveredParam> workingList;
  // Settings > Miscellaneous. 0 = never filter.
  final int noiseThreshold;
  final Map<String, DateTime> lastChanged = {};
  final Set<String> _noisy = {};
  // per-param change counts, bucketed by whole second.
  final Map<String, Map<int, int>> _perSecond = {};
  final Map<String, List<DateTime>> _bursts = {};

  LiveParamTracker(this.workingList, {required this.noiseThreshold});

  static const _rateWindowSeconds = 5;
  static const _rateSecondsNeeded = 3;
  // one wiggle sends a burst of updates - changes closer together than
  // this belong to the same burst.
  static const _burstGap = Duration(milliseconds: 750);
  static const _burstWindow = Duration(seconds: 30);
  static const _maxBurstsInWindow = 6;

  bool isNoisy(String name) => _noisy.contains(name);

  /// true if the visible list changed (a new param, or a reorder).
  bool handleChange(String name, DiscoveredKind kind, {DateTime? at}) {
    var changed = false;
    if (!workingList.any((p) => p.name == name)) {
      workingList = [
        ...workingList,
        DiscoveredParam(name, kind, readOnly: vrchatReadOnlyBuiltins.contains(name)),
      ];
      changed = true;
    }
    if (_noisy.contains(name)) return changed;
    final now = at ?? DateTime.now();

    if (noiseThreshold > 0) {
      final second = now.millisecondsSinceEpoch ~/ 1000;
      final buckets = _perSecond.putIfAbsent(name, () => {});
      buckets[second] = (buckets[second] ?? 0) + 1;
      buckets.removeWhere((s, _) => s <= second - _rateWindowSeconds);
      final busySeconds = buckets.values.where((c) => c >= noiseThreshold).length;
      if (busySeconds >= _rateSecondsNeeded) return _markNoisy(name);
    }

    final previous = lastChanged[name];
    if (previous != null && now.difference(previous) < _burstGap) {
      // same burst - keep it highlighted, but it's not a new promotion.
      lastChanged[name] = now;
      return changed;
    }
    final bursts = _bursts.putIfAbsent(name, () => []);
    bursts.add(now);
    bursts.removeWhere((t) => now.difference(t) > _burstWindow);
    if (noiseThreshold > 0 && bursts.length > _maxBurstsInWindow) return _markNoisy(name);
    lastChanged[name] = now;
    return true;
  }

  bool _markNoisy(String name) {
    _noisy.add(name);
    lastChanged.remove(name);
    return true;
  }

  List<DiscoveredParam> sorted(List<DiscoveredParam> base) {
    if (lastChanged.isEmpty) return base;
    return [...base]..sort((a, b) {
        final at = lastChanged[a.name];
        final bt = lastChanged[b.name];
        if (at == null && bt == null) return 0;
        if (at == null) return 1;
        if (bt == null) return -1;
        return bt.compareTo(at);
      });
  }
}
