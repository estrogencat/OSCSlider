import 'package:flutter/material.dart';

import 'discovery_sheet.dart';
import 'error_dialog.dart';
import 'oscquery_client.dart';
import 'param_control.dart';
import 'param_form_dialog.dart';

/// editor for one "Save Parameters" snapshot's own parameter list - rename
/// it, or add/remove which parameters it tracks. snapshot values are static
/// (frozen at save/apply time), so unlike the main screen/sequence editor
/// there's no live OSC value to drag here, just membership.
class SnapshotEditorPage extends StatefulWidget {
  final Profile snapshot;
  final bool developerMode;
  // the active profile's configured OSC port - only needed for the discover
  // popup's "highlight active parameters" listener, which taps port+1.
  final int oscPort;
  // Settings > Miscellaneous - see LiveParamTracker.noiseThreshold.
  final int liveParamNoiseThreshold;
  // Settings > Miscellaneous (developer mode only).
  final int oscQueryFetchTimeoutSeconds;
  final VoidCallback onPersist;

  const SnapshotEditorPage({
    super.key,
    required this.snapshot,
    required this.developerMode,
    required this.oscPort,
    required this.liveParamNoiseThreshold,
    required this.oscQueryFetchTimeoutSeconds,
    required this.onPersist,
  });

  @override
  State<SnapshotEditorPage> createState() => _SnapshotEditorPageState();
}

class _SnapshotEditorPageState extends State<SnapshotEditorPage> {
  late final TextEditingController _nameController;
  final _searchController = TextEditingController();
  String _searchQuery = '';
  bool _discovering = false;
  // developer-mode-only escape hatch: a second Discover click within 1s of a
  // "nothing found" failure opens the add menu anyway, empty - same shortcut
  // as the main screen's discover icon.
  DateTime? _lastDiscoverFailure;

  Profile get snapshot => widget.snapshot;

  @override
  void initState() {
    super.initState();
    _nameController = TextEditingController(text: snapshot.name);
  }

  @override
  void dispose() {
    _nameController.dispose();
    _searchController.dispose();
    super.dispose();
  }

  void _renameSnapshot(String value) {
    final trimmed = value.trim();
    if (trimmed.isEmpty || trimmed == snapshot.name) return;
    setState(() => snapshot.name = trimmed);
    widget.onPersist();
  }

  Future<void> _deleteParam(ParamControl param) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Remove parameter?'),
        content: Text('Remove "${param.label}" from this snapshot?'),
        actions: [
          TextButton(onPressed: () => Navigator.of(context).pop(false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.of(context).pop(true), child: const Text('Remove')),
        ],
      ),
    );
    if (confirmed != true) return;
    setState(() => snapshot.parameters.remove(param));
    widget.onPersist();
  }

  Future<void> _editParam(ParamControl param) async {
    final result = await showParamFormDialog(context, existing: param);
    if (result == null) return;
    final index = snapshot.parameters.indexOf(param);
    if (index == -1) return;
    setState(() => snapshot.parameters[index] = result);
    widget.onPersist();
  }

  // overwrites this one saved value with whatever the parameter is currently
  // set to live on the avatar - a quick re-capture without redoing the whole
  // "Save Parameters" flow. read-only against OSC, nothing is sent.
  Future<void> _fetchValue(ParamControl param) async {
    final messenger = ScaffoldMessenger.of(context);
    final result = await OscQueryClient.findVrchatInstances(anyOscQueryService: widget.developerMode);
    if (!mounted) return;
    if (result.instances.isEmpty) {
      await showErrorDialog(context, 'No OSCQuery service found', result.error ?? oscNotFoundExplanation);
      return;
    }
    final (host, port) = result.instances.first;
    final Object? value;
    try {
      value = await OscQueryClient.fetchParameterValue(host, port, param.name);
    } catch (e) {
      if (!mounted) return;
      await showErrorDialog(context, 'Could not fetch "${param.label}"', e.toString());
      return;
    }
    if (!mounted) return;
    if (value == null) {
      await showErrorDialog(
        context,
        'Parameter not found',
        'Could not find "${param.label}" on the avatar - it may not exist under that name.',
      );
      return;
    }
    if (param.type == ParamType.toggle && value is bool) {
      final boolValue = value;
      setState(() => param.defaultBool = boolValue);
    } else if (param.type == ParamType.slider && value is double) {
      final doubleValue = value;
      setState(() => param.defaultValue = doubleValue);
    } else {
      messenger.showSnackBar(SnackBar(content: Text('"${param.label}" is a different type on the avatar - not applied.')));
      return;
    }
    widget.onPersist();
  }

  Future<void> _showParamContextMenu(BuildContext context, Offset globalPosition, ParamControl param) async {
    final overlay = Overlay.of(context).context.findRenderObject() as RenderBox;
    final selected = await showMenu<String>(
      context: context,
      position: RelativeRect.fromLTRB(
        globalPosition.dx,
        globalPosition.dy,
        overlay.size.width - globalPosition.dx,
        overlay.size.height - globalPosition.dy,
      ),
      items: [
        const PopupMenuItem(value: 'edit', child: Text('Edit')),
        if (param.type != ParamType.custom) const PopupMenuItem(value: 'fetch', child: Text('Fetch value')),
        const PopupMenuItem(value: 'delete', child: Text('Delete')),
      ],
    );
    if (selected == 'delete') {
      await _deleteParam(param);
    } else if (selected == 'edit') {
      await _editParam(param);
    } else if (selected == 'fetch') {
      await _fetchValue(param);
    }
  }

  // dragging the inline slider/switch edits the saved value directly - same
  // paradigm as the sequence editor's step targets, no OSC involved since
  // this is a static save, not a live parameter.
  void _setParamValue(ParamControl param, double value) {
    setState(() => param.defaultValue = value);
  }

  void _setParamBool(ParamControl param, bool value) {
    setState(() => param.defaultBool = value);
    widget.onPersist();
  }

  String _fmt(double v) => v == v.roundToDouble() ? v.toStringAsFixed(0) : v.toStringAsFixed(2);

  Future<void> _openDiscoverySheet(
    List<DiscoveredParam> found, {
    bool fetchFailed = false,
    String? failureDetail,
  }) async {
    await showDiscoveryResultsSheet(
      context,
      found: found,
      autoStartLive: fetchFailed,
      fetchFailed: fetchFailed,
      failureDetail: failureDetail,
      developerMode: widget.developerMode,
      avatarChangeListenPort: widget.oscPort + 1,
      noiseThreshold: widget.liveParamNoiseThreshold,
      existingNames: snapshot.parameters.map((p) => p.name).toSet(),
      onAdd: (control) {
        setState(() => snapshot.parameters.add(control));
        widget.onPersist();
      },
    );
  }

  Future<void> _discover() async {
    final devMode = widget.developerMode;
    if (devMode &&
        _lastDiscoverFailure != null &&
        DateTime.now().difference(_lastDiscoverFailure!) <= const Duration(seconds: 1)) {
      _lastDiscoverFailure = null;
      await _openDiscoverySheet(const []);
      return;
    }

    setState(() => _discovering = true);
    try {
      final fetchTimeout = Duration(seconds: widget.oscQueryFetchTimeoutSeconds);
      final result = await OscQueryClient.findVrchatInstances(anyOscQueryService: devMode, timeout: fetchTimeout);
      if (!mounted) return;
      if (result.instances.isEmpty) {
        _lastDiscoverFailure = devMode ? DateTime.now() : null;
        await showErrorDialog(
          context,
          'No OSCQuery service found',
          (result.error ?? oscNotFoundExplanation) +
              (devMode ? '\n\nClick Discover again within 1s to bring up the add menu anyway (developer mode).' : ''),
        );
        return;
      }
      final (host, port) = result.instances.first;
      List<DiscoveredParam> found;
      var fetchFailed = false;
      String? failureDetail;
      try {
        found = await OscQueryClient.fetchAvatarParameters(host, port, perAttemptTimeout: fetchTimeout);
      } catch (e) {
        // some avatars' full parameter tree makes VRChat's own OSCQuery HTTP
        // server hang outright - fall back to building the list from live
        // outgoing OSC traffic instead of blocking the whole feature on it.
        found = const [];
        fetchFailed = true;
        failureDetail = e.toString();
      }
      if (!mounted) return;
      await _openDiscoverySheet(found, fetchFailed: fetchFailed, failureDetail: failureDetail);
    } catch (e) {
      if (!mounted) return;
      await showErrorDialog(context, 'Discovery failed', e.toString());
    } finally {
      if (mounted) setState(() => _discovering = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final query = _searchQuery.toLowerCase();
    final params = snapshot.parameters;
    final filtered = query.isEmpty
        ? params
        : params.where((p) => p.label.toLowerCase().contains(query) || p.name.toLowerCase().contains(query)).toList();
    return Scaffold(
      appBar: AppBar(title: const Text('Edit Snapshot')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          TextField(
            controller: _nameController,
            decoration: const InputDecoration(labelText: 'Name'),
            onSubmitted: _renameSnapshot,
            onTapOutside: (_) => _renameSnapshot(_nameController.text),
          ),
          const SizedBox(height: 20),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text('Parameters', style: Theme.of(context).textTheme.titleLarge),
              IconButton(
                icon: _discovering
                    ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
                    : const Icon(Icons.wifi_find),
                tooltip: 'Discover parameters from running VRChat (OSCQuery)',
                onPressed: _discovering ? null : _discover,
              ),
            ],
          ),
          SearchBar(
            controller: _searchController,
            hintText: 'Search parameters',
            leading: const Icon(Icons.search),
            trailing: _searchQuery.isEmpty
                ? null
                : [
                    IconButton(
                      icon: const Icon(Icons.clear),
                      onPressed: () {
                        _searchController.clear();
                        setState(() => _searchQuery = '');
                      },
                    ),
                  ],
            onChanged: (v) => setState(() => _searchQuery = v),
          ),
          const SizedBox(height: 8),
          if (params.isEmpty)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 8),
              child: Text('No parameters saved. Tap the discover icon to add some.'),
            )
          else if (filtered.isEmpty)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 8),
              child: Text('No parameters match your search.'),
            )
          else
            for (final p in filtered)
              GestureDetector(
                onSecondaryTapDown: (details) => _showParamContextMenu(context, details.globalPosition, p),
                child: Card(
                  margin: const EdgeInsets.symmetric(vertical: 4),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 4),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        ListTile(
                          title: Text(p.label),
                          subtitle: Text(p.name),
                          trailing: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              IconButton(icon: const Icon(Icons.edit), onPressed: () => _editParam(p)),
                              IconButton(
                                icon: const Icon(Icons.delete_outline),
                                onPressed: () => _deleteParam(p),
                              ),
                            ],
                          ),
                        ),
                        if (p.type == ParamType.slider)
                          Padding(
                            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                            child: Row(
                              children: [
                                Expanded(
                                  child: Slider(
                                    value: p.defaultValue.clamp(p.min, p.max),
                                    min: p.min,
                                    max: p.max,
                                    onChanged: (v) => _setParamValue(p, v),
                                    onChangeEnd: (_) => widget.onPersist(),
                                  ),
                                ),
                                SizedBox(width: 56, child: Text(_fmt(p.defaultValue), textAlign: TextAlign.end)),
                              ],
                            ),
                          )
                        else if (p.type == ParamType.toggle)
                          Padding(
                            padding: const EdgeInsets.fromLTRB(16, 0, 8, 8),
                            child: Row(
                              children: [
                                Text(p.defaultBool ? 'On' : 'Off'),
                                const Spacer(),
                                Switch(value: p.defaultBool, onChanged: (v) => _setParamBool(p, v)),
                              ],
                            ),
                          )
                        else
                          Padding(
                            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                            child: Text(
                              'custom - type "${p.customTypeTag}"',
                              style: Theme.of(context).textTheme.bodySmall,
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
              ),
        ],
      ),
    );
  }
}
