import 'package:flutter/material.dart';

import 'automation_dialog.dart';
import 'discovery_sheet.dart';
import 'error_dialog.dart';
import 'osc_client.dart';
import 'oscquery_client.dart';
import 'param_control.dart';
import 'param_form_dialog.dart';
import 'trigger_fields.dart';

/// full-page editor for one sequence - its own settings/steps, plus a full
/// parameter/automation panel (mirroring the main screen) so a sequence can
/// be built end-to-end without leaving the page. the parameter panel reads
/// and writes the SAME shared parameter list/live values/OSC client as the
/// main screen - it's one more place to manage them, not a separate copy.
class SequenceEditorPage extends StatefulWidget {
  final AutomationSequence sequence;
  final AppConfig config;
  final Map<String, Object> values;
  final Map<String, TextEditingController> sliderTextControllers;
  final Map<String, TextEditingController> customValueControllers;
  final OscClient? osc;
  final bool advancedMode;
  final bool developerMode;
  final VoidCallback onPersist;
  final void Function(ParamControl param) onInteraction;

  const SequenceEditorPage({
    super.key,
    required this.sequence,
    required this.config,
    required this.values,
    required this.sliderTextControllers,
    required this.customValueControllers,
    required this.osc,
    required this.advancedMode,
    required this.developerMode,
    required this.onPersist,
    required this.onInteraction,
  });

  @override
  State<SequenceEditorPage> createState() => _SequenceEditorPageState();
}

class _SequenceEditorPageState extends State<SequenceEditorPage> {
  late final TextEditingController _nameController;
  late final TextEditingController _repeatCountController;
  late final TextEditingController _triggerThreshold;
  late final TextEditingController _triggerRangeMin;
  late final TextEditingController _triggerRangeMax;
  late final TextEditingController _triggerRequiredHits;

  final _paramSearchController = TextEditingController();
  String _paramSearchQuery = '';
  bool _discovering = false;
  // developer-mode-only escape hatch: a second Discover click within 1s of a
  // "nothing found" failure opens the add menu anyway, empty - same shortcut
  // as the main screen's discover icon.
  DateTime? _lastDiscoverFailure;

  AutomationSequence get seq => widget.sequence;
  List<ParamControl> get _parameters => widget.config.parameters;

  // only sliders/toggles are settable step targets - custom-type params have
  // no single "value" this app can drive.
  List<ParamControl> get _eligibleParams =>
      _parameters.where((p) => p.type == ParamType.slider || p.type == ParamType.toggle).toList();

  ParamControl? _findEligible(String name) => _eligibleParams.where((p) => p.name == name).firstOrNull;

  @override
  void initState() {
    super.initState();
    _nameController = TextEditingController(text: seq.name);
    _repeatCountController = TextEditingController(text: '${seq.repeatCount}');
    _triggerThreshold = TextEditingController(text: _fmt(seq.trigger?.threshold ?? 0.5));
    _triggerRangeMin = TextEditingController(text: _fmt(seq.trigger?.rangeMin ?? 0.25));
    _triggerRangeMax = TextEditingController(text: _fmt(seq.trigger?.rangeMax ?? 0.75));
    _triggerRequiredHits = TextEditingController(text: '${seq.trigger?.requiredHits ?? 1}');
  }

  @override
  void dispose() {
    _nameController.dispose();
    _repeatCountController.dispose();
    _triggerThreshold.dispose();
    _triggerRangeMin.dispose();
    _triggerRangeMax.dispose();
    _triggerRequiredHits.dispose();
    _paramSearchController.dispose();
    super.dispose();
  }

  void _renameSequence(String value) {
    setState(() => seq.name = value.trim().isEmpty ? seq.name : value.trim());
  }

  void _setRepeatMode(SequenceRepeatMode mode) {
    setState(() => seq.repeatMode = mode);
  }

  void _setRepeatCount(String value) {
    setState(() => seq.repeatCount = int.tryParse(value)?.clamp(0, 1000000) ?? 0);
  }

  void _setEnabled(bool value) {
    setState(() => seq.enabled = value);
  }

  bool get _triggerEnabled => seq.trigger?.enabled ?? false;
  String? get _watchedParamName => seq.trigger?.watchedParamName;
  ToggleTriggerCondition get _toggleCondition => seq.trigger?.toggleCondition ?? ToggleTriggerCondition.turnsOn;
  RangeTriggerCondition get _rangeCondition => seq.trigger?.rangeCondition ?? RangeTriggerCondition.above;

  void _setTriggerEnabled(bool value) {
    setState(() {
      seq.trigger ??= ParamTrigger(watchedParamName: _eligibleParams.isEmpty ? '' : _eligibleParams.first.name);
      seq.trigger!.enabled = value;
    });
  }

  void _setWatchedParam(String name) {
    setState(() {
      seq.trigger ??= ParamTrigger();
      seq.trigger!.watchedParamName = name;
    });
  }

  void _setToggleCondition(ToggleTriggerCondition c) {
    setState(() {
      seq.trigger ??= ParamTrigger();
      seq.trigger!.toggleCondition = c;
    });
  }

  void _setRangeCondition(RangeTriggerCondition c) {
    setState(() {
      seq.trigger ??= ParamTrigger();
      seq.trigger!.rangeCondition = c;
    });
  }

  void _setTriggerThreshold(String text) {
    final v = double.tryParse(text);
    if (v != null) setState(() => (seq.trigger ??= ParamTrigger()).threshold = v);
  }

  void _setTriggerRangeMin(String text) {
    final v = double.tryParse(text);
    if (v != null) setState(() => (seq.trigger ??= ParamTrigger()).rangeMin = v);
  }

  void _setTriggerRangeMax(String text) {
    final v = double.tryParse(text);
    if (v != null) setState(() => (seq.trigger ??= ParamTrigger()).rangeMax = v);
  }

  void _setTriggerRequiredHits(String text) {
    final v = int.tryParse(text);
    if (v != null) setState(() => (seq.trigger ??= ParamTrigger()).requiredHits = v < 1 ? 1 : v);
  }

  void _reorder(int oldIndex, int newIndex) {
    setState(() {
      if (newIndex > oldIndex) newIndex -= 1;
      final step = seq.steps.removeAt(oldIndex);
      seq.steps.insert(newIndex, step);
    });
  }

  Future<void> _addStep() async {
    if (_eligibleParams.isEmpty) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('No slider/toggle parameters to target yet.')));
      return;
    }
    final step = await _showStepDialog(context, null, _eligibleParams);
    if (step != null) setState(() => seq.steps.add(step));
  }

  Future<void> _editStep(int index) async {
    final result = await _showStepDialog(context, seq.steps[index], _eligibleParams);
    if (result == null) return;
    // mutate the existing step in place (rather than replacing it) so its
    // identity - and the reorderable list's key for it - stays stable.
    setState(() {
      final step = seq.steps[index];
      step.kind = result.kind;
      step.paramName = result.paramName;
      step.targetValue = result.targetValue;
      step.targetBool = result.targetBool;
      step.durationSeconds = result.durationSeconds;
    });
  }

  // removes only this step from the sequence's own step list - never
  // touches config.parameters, so it can't delete the underlying parameter
  // from the main screen no matter how it's triggered (icon or this menu).
  void _deleteStep(int index) {
    setState(() => seq.steps.removeAt(index));
  }

  Future<void> _showStepContextMenu(BuildContext context, Offset globalPosition, int index) async {
    final overlay = Overlay.of(context).context.findRenderObject() as RenderBox;
    final selected = await showMenu<String>(
      context: context,
      position: RelativeRect.fromLTRB(
        globalPosition.dx,
        globalPosition.dy,
        overlay.size.width - globalPosition.dx,
        overlay.size.height - globalPosition.dy,
      ),
      items: const [
        PopupMenuItem(value: 'edit', child: Text('Edit')),
        PopupMenuItem(value: 'delete', child: Text('Delete')),
      ],
    );
    if (selected == 'delete') {
      _deleteStep(index);
    } else if (selected == 'edit') {
      await _editStep(index);
    }
  }

  // dragging the inline slider/switch updates the step's target directly -
  // the same value editing the main screen offers for the live parameter
  // itself, just applied to what this step will set it to.
  void _setStepTargetValue(int index, double value) {
    setState(() => seq.steps[index].targetValue = value);
  }

  void _setStepTargetBool(int index, bool value) {
    setState(() => seq.steps[index].targetBool = value);
  }

  String _stepTitle(SequenceStep step) {
    final param = _eligibleParams.where((p) => p.name == step.paramName).firstOrNull;
    final label = param?.label ?? step.paramName;
    if (param?.type == ParamType.toggle) {
      return 'Set "$label", hold ${_fmt(step.durationSeconds)}s';
    }
    return 'Set "$label" over ${_fmt(step.durationSeconds)}s';
  }

  String _fmt(double v) => v == v.roundToDouble() ? v.toStringAsFixed(0) : v.toStringAsFixed(2);

  // ---- parameter panel (mirrors the main screen's add/edit/automation) ----

  void _initValueAndController(ParamControl p) {
    switch (p.type) {
      case ParamType.toggle:
        widget.values[p.name] = p.defaultBool;
      case ParamType.slider:
        widget.values[p.name] = p.defaultValue;
        widget.sliderTextControllers[p.name] =
            TextEditingController(text: formatParamNumber(p.defaultValue, widget.advancedMode));
      case ParamType.custom:
        widget.customValueControllers[p.name] = TextEditingController(text: p.customValueText);
    }
  }

  // owned by this sequence, not the parameter - never touches or enables
  // param.automation. runs continuously (via _tickEngines in main.dart)
  // for as long as this sequence itself is enabled/running.
  Future<void> _openAutomationDialog(ParamControl param) async {
    final result = await showSequenceParamAutomationDialog(
      context,
      param,
      _parameters,
      seq.paramAutomations[param.name],
    );
    if (!result.changed) return;
    setState(() {
      if (result.automation == null) {
        seq.paramAutomations.remove(param.name);
      } else {
        seq.paramAutomations[param.name] = result.automation!;
      }
    });
    widget.onPersist();
  }

  Widget _automationButton(ParamControl param) {
    final auto = seq.paramAutomations[param.name];
    final configured = auto != null;
    // a step in this same sequence targeting the same parameter always wins
    // over this automation - the engine suppresses the automation's ticks
    // while that holds (see main.dart's _tickEngines), rather than letting
    // both send competing OSC values every tick.
    final stepConflict =
        configured && seq.steps.any((s) => s.kind == SequenceStepKind.setValue && s.paramName == param.name);
    final running = configured && seq.enabled && auto.enabled && !stepConflict;
    final paused = configured && !auto.enabled;
    final scheme = Theme.of(context).colorScheme;
    return IconButton(
      icon: Icon(running ? Icons.auto_awesome : Icons.auto_awesome_outlined),
      color: running ? scheme.primary : (configured ? scheme.onSurfaceVariant : scheme.outline),
      tooltip: stepConflict
          ? 'A step in this sequence also targets this parameter - automation suppressed while any step does, tap to edit'
          : running
              ? 'Automation running in this sequence - tap to edit'
              : paused
                  ? 'Automation paused in this sequence - tap to edit'
                  : (configured ? 'Automation set, sequence not running - tap to edit' : 'Add automation for this sequence'),
      onPressed: () => _openAutomationDialog(param),
    );
  }

  void _onParamSliderChanged(ParamControl param, double value) {
    widget.onInteraction(param);
    setState(() => widget.values[param.name] = value);
    widget.sliderTextControllers[param.name]?.text = formatParamNumber(value, widget.advancedMode);
    _sendParamSlider(param, value);
  }

  void _sendParamSlider(ParamControl param, double value) {
    final address = oscAddressFor(param);
    if (param.numericKind == NumericKind.int) {
      widget.osc?.sendInt(address, value.round());
    } else {
      widget.osc?.sendFloat(address, value);
    }
  }

  void _onParamSliderTextSubmitted(ParamControl param, String text) {
    final value = double.tryParse(text);
    if (value == null) {
      widget.sliderTextControllers[param.name]?.text =
          formatParamNumber(widget.values[param.name] as double? ?? param.defaultValue, widget.advancedMode);
      return;
    }
    widget.onInteraction(param);
    setState(() => widget.values[param.name] = value);
    widget.sliderTextControllers[param.name]?.text = formatParamNumber(value, widget.advancedMode);
    _sendParamSlider(param, value);
  }

  void _onParamToggleChanged(ParamControl param, bool value) {
    widget.onInteraction(param);
    setState(() => widget.values[param.name] = value);
    widget.osc?.sendBool(oscAddressFor(param), value);
  }

  Future<void> _sendParamCustom(ParamControl param) async {
    final text = widget.customValueControllers[param.name]?.text ?? param.customValueText;
    try {
      await widget.osc?.sendCustom(oscAddressFor(param), param.customTypeTag, text);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Send failed: $e')));
    }
  }

  Future<void> _deleteParam(ParamControl param) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete parameter?'),
        content: Text('Remove "${param.label}" from the dashboard?'),
        actions: [
          TextButton(onPressed: () => Navigator.of(context).pop(false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.of(context).pop(true), child: const Text('Delete')),
        ],
      ),
    );
    if (confirmed != true) return;
    setState(() {
      _parameters.remove(param);
      widget.sliderTextControllers.remove(param.name)?.dispose();
      widget.customValueControllers.remove(param.name)?.dispose();
      widget.values.remove(param.name);
    });
    widget.onPersist();
  }

  Future<void> _editParam(ParamControl param) async {
    final result = await showParamFormDialog(context, existing: param);
    if (result == null) return;
    final index = _parameters.indexOf(param);
    if (index != -1) _parameters[index] = result;
    // the edited param's name/type may have changed, so drop its old
    // controller/value first and reinitialize just this one.
    widget.sliderTextControllers.remove(param.name)?.dispose();
    widget.customValueControllers.remove(param.name)?.dispose();
    widget.values.remove(param.name);
    setState(() => _initValueAndController(result));
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

  // pulls the parameter's current live value from VRChat's OSCQuery tree and
  // snaps the local display to it - read-only, nothing is sent back over OSC.
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
    widget.onInteraction(param);
    if (param.type == ParamType.toggle && value is bool) {
      final boolValue = value;
      setState(() => widget.values[param.name] = boolValue);
    } else if (param.type == ParamType.slider && value is double) {
      final doubleValue = value;
      setState(() => widget.values[param.name] = doubleValue);
      widget.sliderTextControllers[param.name]?.text = formatParamNumber(doubleValue, widget.advancedMode);
    } else {
      messenger.showSnackBar(SnackBar(content: Text('"${param.label}" is a different type on the avatar - not applied.')));
    }
  }

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
      avatarChangeListenPort: widget.config.port + 1,
      noiseThreshold: widget.config.liveParamNoiseThreshold,
      existingNames: _parameters.map((p) => p.name).toSet(),
      onAdd: (control) {
        _parameters.add(control);
        setState(() => _initValueAndController(control));
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
      final fetchTimeout = Duration(seconds: widget.config.oscQueryFetchTimeoutSeconds);
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

  Widget _buildParametersSection(BuildContext context) {
    final params = _parameters;
    final query = _paramSearchQuery.toLowerCase();
    final filtered = query.isEmpty
        ? params
        : params.where((p) => p.label.toLowerCase().contains(query) || p.name.toLowerCase().contains(query)).toList();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
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
          controller: _paramSearchController,
          hintText: 'Search parameters',
          leading: const Icon(Icons.search),
          trailing: _paramSearchQuery.isEmpty
              ? null
              : [
                  IconButton(
                    icon: const Icon(Icons.clear),
                    onPressed: () {
                      _paramSearchController.clear();
                      setState(() => _paramSearchQuery = '');
                    },
                  ),
                ],
          onChanged: (v) => setState(() => _paramSearchQuery = v),
        ),
        const SizedBox(height: 8),
        if (params.isEmpty)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 8),
            child: Text('No parameters yet. Tap the discover icon to add some.'),
          )
        else if (filtered.isEmpty)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 8),
            child: Text('No parameters match your search.'),
          )
        else
          for (final p in filtered) _buildParamCard(context, p),
      ],
    );
  }

  Widget _buildParamCard(BuildContext context, ParamControl param) {
    Widget child;
    switch (param.type) {
      case ParamType.toggle:
        final value = widget.values[param.name] as bool? ?? param.defaultBool;
        child = Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
          child: Row(
            children: [
              Expanded(child: Text(param.label, style: Theme.of(context).textTheme.titleMedium)),
              _automationButton(param),
              Switch(value: value, onChanged: (v) => _onParamToggleChanged(param, v)),
            ],
          ),
        );
      case ParamType.custom:
        final controller = widget.customValueControllers[param.name];
        child = Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(param.label, style: Theme.of(context).textTheme.titleMedium),
                    Text('custom - type "${param.customTypeTag}"', style: Theme.of(context).textTheme.bodySmall),
                  ],
                ),
              ),
              SizedBox(
                width: 140,
                child: TextField(controller: controller, decoration: const InputDecoration(isDense: true)),
              ),
              IconButton(icon: const Icon(Icons.send), onPressed: () => _sendParamCustom(param)),
            ],
          ),
        );
      case ParamType.slider:
        final value = widget.values[param.name] as double? ?? param.defaultValue;
        final textController = widget.sliderTextControllers[param.name];
        child = Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Expanded(child: Text(param.label, style: Theme.of(context).textTheme.titleMedium)),
                  _automationButton(param),
                  SizedBox(
                    width: 90,
                    child: TextField(
                      controller: textController,
                      textAlign: TextAlign.end,
                      keyboardType: const TextInputType.numberWithOptions(signed: true, decimal: true),
                      decoration: const InputDecoration(isDense: true),
                      onSubmitted: (text) => _onParamSliderTextSubmitted(param, text),
                    ),
                  ),
                ],
              ),
              Slider(
                value: value.clamp(param.min, param.max),
                min: param.min,
                max: param.max,
                onChanged: (v) => _onParamSliderChanged(param, v),
              ),
            ],
          ),
        );
    }

    return GestureDetector(
      onSecondaryTapDown: (details) => _showParamContextMenu(context, details.globalPosition, param),
      child: Card(margin: const EdgeInsets.symmetric(vertical: 8), child: child),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Edit Sequence')),
      body: CustomScrollView(
        slivers: [
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
            sliver: SliverToBoxAdapter(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  TextField(
                    controller: _nameController,
                    decoration: const InputDecoration(labelText: 'Name'),
                    onSubmitted: _renameSequence,
                    onTapOutside: (_) => _renameSequence(_nameController.text),
                  ),
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      const Expanded(child: Text('Running')),
                      Switch(value: seq.enabled, onChanged: _setEnabled),
                    ],
                  ),
                  const SizedBox(height: 8),
                  DropdownButtonFormField<SequenceRepeatMode>(
                    initialValue: seq.repeatMode,
                    decoration: const InputDecoration(labelText: 'Repeat'),
                    items: const [
                      DropdownMenuItem(value: SequenceRepeatMode.once, child: Text('Once through')),
                      DropdownMenuItem(value: SequenceRepeatMode.loop, child: Text('Loop from step 1')),
                    ],
                    onChanged: (v) => _setRepeatMode(v ?? SequenceRepeatMode.once),
                  ),
                  if (seq.repeatMode == SequenceRepeatMode.loop) ...[
                    const SizedBox(height: 8),
                    TextField(
                      controller: _repeatCountController,
                      keyboardType: TextInputType.number,
                      decoration: const InputDecoration(labelText: 'Repeat count (0 = forever)'),
                      onSubmitted: _setRepeatCount,
                      onTapOutside: (_) => _setRepeatCount(_repeatCountController.text),
                    ),
                  ],
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      const Expanded(child: Text('Triggered by another parameter')),
                      Switch(value: _triggerEnabled, onChanged: _setTriggerEnabled),
                    ],
                  ),
                  if (_triggerEnabled) ...[
                    const SizedBox(height: 8),
                    TriggerFields(
                      eligibleParams: _eligibleParams,
                      watchedParamName: _watchedParamName,
                      toggleCondition: _toggleCondition,
                      rangeCondition: _rangeCondition,
                      thresholdController: _triggerThreshold,
                      rangeMinController: _triggerRangeMin,
                      rangeMaxController: _triggerRangeMax,
                      requiredHitsController: _triggerRequiredHits,
                      onWatchedParamChanged: _setWatchedParam,
                      onToggleConditionChanged: _setToggleCondition,
                      onRangeConditionChanged: _setRangeCondition,
                      onThresholdChanged: _setTriggerThreshold,
                      onRangeMinChanged: _setTriggerRangeMin,
                      onRangeMaxChanged: _setTriggerRangeMax,
                      onRequiredHitsChanged: _setTriggerRequiredHits,
                    ),
                  ],
                  const SizedBox(height: 20),
                  const Divider(),
                  const SizedBox(height: 8),
                  _buildParametersSection(context),
                  const SizedBox(height: 20),
                  const Divider(),
                  const SizedBox(height: 8),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text('Steps', style: Theme.of(context).textTheme.titleLarge),
                      TextButton.icon(onPressed: _addStep, icon: const Icon(Icons.add), label: const Text('Add step')),
                    ],
                  ),
                ],
              ),
            ),
          ),
          if (seq.steps.isEmpty)
            const SliverToBoxAdapter(
              child: Padding(
                padding: EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                child: Text('No steps yet - add one to start scripting this sequence.'),
              ),
            )
          else
            SliverPadding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              sliver: SliverReorderableList(
                itemCount: seq.steps.length,
                onReorderItem: _reorder,
                itemBuilder: (context, index) {
                  final step = seq.steps[index];
                  final param =
                      step.kind == SequenceStepKind.setValue ? _findEligible(step.paramName) : null;
                  return GestureDetector(
                    key: ValueKey(identityHashCode(step)),
                    onSecondaryTapDown: (details) =>
                        _showStepContextMenu(context, details.globalPosition, index),
                    child: Card(
                      margin: const EdgeInsets.symmetric(vertical: 4),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(vertical: 4),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            ListTile(
                              leading: ReorderableDragStartListener(
                                index: index,
                                child: const Icon(Icons.drag_handle),
                              ),
                              title: Text(
                                step.kind == SequenceStepKind.wait
                                    ? '${index + 1}. Wait ${_fmt(step.durationSeconds)}s'
                                    : '${index + 1}. ${_stepTitle(step)}',
                              ),
                              subtitle: step.kind == SequenceStepKind.setValue && param == null
                                  ? const Text('Target parameter no longer exists')
                                  : null,
                              trailing: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  IconButton(icon: const Icon(Icons.edit), onPressed: () => _editStep(index)),
                                  IconButton(
                                    icon: const Icon(Icons.delete_outline),
                                    onPressed: () => _deleteStep(index),
                                  ),
                                ],
                              ),
                            ),
                            if (param != null && param.type == ParamType.slider)
                              Padding(
                                padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
                                child: Row(
                                  children: [
                                    Expanded(
                                      child: Slider(
                                        value: step.targetValue.clamp(param.min, param.max),
                                        min: param.min,
                                        max: param.max,
                                        onChanged: (v) => _setStepTargetValue(index, v),
                                      ),
                                    ),
                                    SizedBox(
                                      width: 56,
                                      child: Text(_fmt(step.targetValue), textAlign: TextAlign.end),
                                    ),
                                  ],
                                ),
                              )
                            else if (param != null && param.type == ParamType.toggle)
                              Padding(
                                padding: const EdgeInsets.fromLTRB(16, 0, 8, 4),
                                child: Row(
                                  children: [
                                    Text(step.targetBool ? 'On' : 'Off'),
                                    const Spacer(),
                                    Switch(
                                      value: step.targetBool,
                                      onChanged: (v) => _setStepTargetBool(index, v),
                                    ),
                                  ],
                                ),
                              ),
                          ],
                        ),
                      ),
                    ),
                  );
                },
              ),
            ),
          const SliverPadding(padding: EdgeInsets.only(bottom: 24)),
        ],
      ),
    );
  }
}

extension _FirstOrNull<T> on Iterable<T> {
  T? get firstOrNull => isEmpty ? null : first;
}

Future<SequenceStep?> _showStepDialog(
  BuildContext context,
  SequenceStep? existing,
  List<ParamControl> eligibleParams,
) {
  return showDialog<SequenceStep>(
    context: context,
    builder: (context) => _StepDialog(existing: existing, eligibleParams: eligibleParams),
  );
}

class _StepDialog extends StatefulWidget {
  final SequenceStep? existing;
  final List<ParamControl> eligibleParams;
  const _StepDialog({required this.existing, required this.eligibleParams});

  @override
  State<_StepDialog> createState() => _StepDialogState();
}

class _StepDialogState extends State<_StepDialog> {
  late SequenceStepKind _kind;
  late String _paramName;
  late final TextEditingController _targetValue;
  late bool _targetBool;
  late final TextEditingController _duration;

  ParamControl? get _param => widget.eligibleParams.where((p) => p.name == _paramName).firstOrNull;

  @override
  void initState() {
    super.initState();
    final e = widget.existing;
    _kind = e?.kind ?? SequenceStepKind.setValue;
    _paramName = e?.paramName ?? widget.eligibleParams.first.name;
    _targetValue = TextEditingController(text: _fmt(e?.targetValue ?? widget.eligibleParams.first.max));
    _targetBool = e?.targetBool ?? true;
    _duration = TextEditingController(text: _fmt(e?.durationSeconds ?? 1.0));
  }

  String _fmt(double v) => v == v.roundToDouble() ? v.toStringAsFixed(0) : v.toString();

  @override
  void dispose() {
    _targetValue.dispose();
    _duration.dispose();
    super.dispose();
  }

  void _save() {
    final param = _param;
    Navigator.of(context).pop(SequenceStep(
      kind: _kind,
      paramName: _kind == SequenceStepKind.setValue ? _paramName : '',
      targetValue: double.tryParse(_targetValue.text) ?? param?.max ?? 1.0,
      targetBool: _targetBool,
      durationSeconds: (double.tryParse(_duration.text) ?? 1.0).abs(),
    ));
  }

  @override
  Widget build(BuildContext context) {
    final param = _param;
    return AlertDialog(
      title: Text(widget.existing == null ? 'Add Step' : 'Edit Step'),
      content: SizedBox(
        width: 380,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            DropdownButtonFormField<SequenceStepKind>(
              initialValue: _kind,
              decoration: const InputDecoration(labelText: 'Step type'),
              items: const [
                DropdownMenuItem(value: SequenceStepKind.setValue, child: Text('Set a parameter\'s value')),
                DropdownMenuItem(value: SequenceStepKind.wait, child: Text('Wait')),
              ],
              onChanged: (v) => setState(() => _kind = v ?? _kind),
            ),
            if (_kind == SequenceStepKind.setValue) ...[
              const SizedBox(height: 8),
              DropdownButtonFormField<String>(
                initialValue: _paramName,
                decoration: const InputDecoration(labelText: 'Parameter'),
                items: [
                  for (final p in widget.eligibleParams) DropdownMenuItem(value: p.name, child: Text(p.label)),
                ],
                onChanged: (v) => setState(() => _paramName = v ?? _paramName),
              ),
              const SizedBox(height: 8),
              if (param?.type == ParamType.toggle)
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Set to'),
                  subtitle: Text(_targetBool ? 'On' : 'Off'),
                  value: _targetBool,
                  onChanged: (v) => setState(() => _targetBool = v),
                )
              else
                TextField(
                  controller: _targetValue,
                  keyboardType: const TextInputType.numberWithOptions(signed: true, decimal: true),
                  decoration: const InputDecoration(labelText: 'Target value'),
                ),
              const SizedBox(height: 8),
              TextField(
                controller: _duration,
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                decoration: InputDecoration(
                  labelText: param?.type == ParamType.toggle ? 'Hold for (seconds)' : 'Glide over (seconds)',
                  helperText: param?.type == ParamType.toggle
                      ? 'Toggles snap instantly, then this step holds before advancing'
                      : '0 = snap instantly',
                ),
              ),
            ] else ...[
              const SizedBox(height: 8),
              TextField(
                controller: _duration,
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                decoration: const InputDecoration(labelText: 'Duration (seconds)'),
              ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Cancel')),
        FilledButton(onPressed: _save, child: const Text('Save')),
      ],
    );
  }
}
