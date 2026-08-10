import 'dart:async';

import 'osc_input_hub.dart';
import 'osc_listener.dart';
import 'oscquery_client.dart';
import 'param_control.dart';

/// temporary read-only tap on the shared OscInputHub for live
/// /avatar/parameters/* traffic - lets the discover popup's "highlight
/// active parameters" toggle surface a name as soon as it changes.
class LiveParamListener {
  final int port;
  final void Function(String paramName, ParamType type) onParamChanged;
  StreamSubscription<OscMessage>? _sub;

  LiveParamListener({required this.port, required this.onParamChanged});

  static const _paramsRoot = '/avatar/parameters/';

  Future<bool> start() async {
    final ok = await oscInputHub.acquire(port);
    if (!ok) return false;
    _sub = oscInputHub.messages.listen((msg) {
      if (!msg.address.startsWith(_paramsRoot) || msg.args.isEmpty) return;
      final name = msg.address.substring(_paramsRoot.length);
      final value = msg.args.first;
      final type = value is bool ? ParamType.toggle : ParamType.slider;
      onParamChanged(name, type);
    });
    return true;
  }

  void stop() {
    _sub?.cancel();
    _sub = null;
    oscInputHub.release();
  }
}

/// tracks which parameters have recently changed while the "highlight active
/// parameters" toggle is on, so they can float to the top - without letting
/// constantly-firing animator/tracking params permanently bury everything else.
class LiveParamTracker {
  List<DiscoveredParam> workingList;
  // Settings > Miscellaneous - changes/sec before a param is treated as noise
  // and stops being promoted. doesn't catch slower recurring noise (every few
  // seconds) - that's what _maxPromotions below is for.
  final int noiseThreshold;
  final Map<String, DateTime> lastChanged = {};
  final Set<String> _noisy = {};
  final Map<String, List<DateTime>> _recentHits = {};
  final Map<String, int> _promotions = {};

  LiveParamTracker(this.workingList, {required this.noiseThreshold});

  static const _noiseWindow = Duration(seconds: 1);
  // caps total promotions regardless of timing - catches slow recurring
  // cycles the 1s noise window alone would miss.
  static const _maxPromotions = 3;

  void handleChange(String name, ParamType type) {
    if (!workingList.any((p) => p.name == name)) {
      workingList = [...workingList, DiscoveredParam(name, type)];
    }
    if (_noisy.contains(name)) return;
    final now = DateTime.now();
    final hits = _recentHits.putIfAbsent(name, () => []);
    hits.add(now);
    hits.removeWhere((t) => now.difference(t) > _noiseWindow);
    final rateNoisy = noiseThreshold > 0 && hits.length >= noiseThreshold;
    final promotions = (_promotions[name] ?? 0) + 1;
    _promotions[name] = promotions;
    if (rateNoisy || promotions > _maxPromotions) {
      _noisy.add(name);
      lastChanged.remove(name);
    } else {
      lastChanged[name] = now;
    }
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
