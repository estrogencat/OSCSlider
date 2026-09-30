import 'dart:collection';

import 'package:flutter/material.dart';

import 'automation_dialog.dart';
import 'discovery_flow.dart';
import 'discovery_sheet.dart';
import 'error_dialog.dart';
import 'live_controller.dart';
import 'param_card.dart';
import 'param_control.dart';
import 'param_form_dialog.dart';
import 'trigger_fields.dart';

/// full-page editor for one sequence - its own settings/steps, plus a full
/// parameter/automation panel (mirroring the main screen) so a sequence can
/// be built end-to-end without leaving the page. the parameter panel reads
/// and writes the SAME shared live state as the main screen - it's one more
/// place to manage them, not a separate copy.
///
/// every change is saved as it's made (writes are coalesced), so nothing is
/// lost if the app closes with this page open.
class SequenceEditorPage extends StatefulWidget {
  final AutomationSequence sequence;
  final LiveController live;

  const SequenceEditorPage({super.key, required this.sequence, required this.live});

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
  bool _showParams = true;

  AutomationSequence get seq => widget.sequence;
  LiveController get live => widget.live;
  List<ParamControl> get _parameters => live.parameters;

  // anything but raw custom-type params can be a step target - custom ones
  // have no single "value" this app can drive.
  List<ParamControl> get _eligibleParams => _parameters.where((p) => p.type != ParamType.custom).toList();

  // triggers can watch anything with a readable value.
  List<ParamControl> get _watchableParams =>
      _parameters.where((p) => p.type == ParamType.slider || p.isBoolLike).toList();

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

  void _update(VoidCallback change) {
    setState(change);
    live.persist();
  }

  void _renameSequence(String value) {
    final trimmed = value.trim();
    if (trimmed.isEmpty || trimmed == seq.name) return;
    _update(() => seq.name = trimmed);
  }

  void _setRepeatCount(String value) {
    final parsed = (int.tryParse(value.trim()) ?? 0).clamp(0, 1000000);
    _repeatCountController.text = '$parsed';
    if (parsed != seq.repeatCount) _update(() => seq.repeatCount = parsed);
  }

  bool get _triggerEnabled => seq.trigger?.enabled ?? false;
  String? get _watchedParamName => seq.trigger?.watchedParamName;
  ToggleTriggerCondition get _toggleCondition => seq.trigger?.toggleCondition ?? ToggleTriggerCondition.turnsOn;
  RangeTriggerCondition get _rangeCondition => seq.trigger?.rangeCondition ?? RangeTriggerCondition.above;

  ParamTrigger _trigger() {
    final eligible = _watchableParams;
    final t = seq.trigger ??= ParamTrigger(watchedParamName: eligible.isEmpty ? '' : eligible.first.name);
    // a watched parameter that's since been deleted - the picker shows the
    // first eligible one, so make that what's actually stored too.
    if (eligible.isNotEmpty && !eligible.any((p) => p.name == t.watchedParamName)) {
      t.watchedParamName = eligible.first.name;
    }
    return t;
  }

  void _setTriggerThreshold(String text) {
    final v = parseUserDouble(text);
    if (v != null) _update(() => _trigger().threshold = v);
  }

  void _setTriggerRangeMin(String text) {
    final v = parseUserDouble(text);
    if (v != null) _update(() => _trigger().rangeMin = v);
  }

  void _setTriggerRangeMax(String text) {
    final v = parseUserDouble(text);
    if (v != null) _update(() => _trigger().rangeMax = v);
  }

  void _setTriggerRequiredHits(String text) {
    final v = int.tryParse(text.trim());
    if (v != null) _update(() => _trigger().requiredHits = v < 1 ? 1 : v);
  }

  // onReorderItem already hands over the index after removal.
  void _reorder(int oldIndex, int newIndex) {
    _update(() {
      final step = seq.steps.removeAt(oldIndex);
      seq.steps.insert(newIndex.clamp(0, seq.steps.length), step);
    });
  }

  Future<void> _addStep() async {
    final step = await _showStepDialog(context, null, _eligibleParams);
    if (step != null) _update(() => seq.steps.add(step));
  }

  Future<void> _editStep(int index) async {
    final result = await _showStepDialog(context, seq.steps[index], _eligibleParams);
    if (result == null || index >= seq.steps.length) return;
    // mutate the existing step in place (rather than replacing it) so its
    // identity - and the reorderable list's key for it - stays stable.
    _update(() {
      final step = seq.steps[index];
      step.kind = result.kind;
      step.paramName = result.paramName;
      step.targetValue = result.targetValue;
      step.targetBool = result.targetBool;
      step.durationSeconds = result.durationSeconds;
      step.text = result.text;
    });
  }

  void _duplicateStep(int index) {
    final s = seq.steps[index];
    _update(() => seq.steps.insert(index + 1, SequenceStep.fromJson(s.toJson())));
  }

  // removes only this step from the sequence's own step list - never
  // touches the parameter itself.
  void _deleteStep(int index) => _update(() => seq.steps.removeAt(index));

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
        PopupMenuItem(value: 'duplicate', child: Text('Duplicate')),
        PopupMenuItem(value: 'delete', child: Text('Delete')),
      ],
    );
    switch (selected) {
      case 'delete':
        _deleteStep(index);
      case 'duplicate':
        _duplicateStep(index);
      case 'edit':
        await _editStep(index);
    }
  }

  String _stepTitle(SequenceStep step) {
    final param = _findEligible(step.paramName);
    final label = param?.label ?? step.paramName;
    if (param?.type == ParamType.toggle) {
      return 'Set "$label" ${step.targetBool ? 'on' : 'off'}, hold ${_fmt(step.durationSeconds)}s';
    }
    if (param?.type == ParamType.button) {
      return 'Press "$label" for ${_fmt(step.durationSeconds < 0.05 ? 0.05 : step.durationSeconds)}s';
    }
    if (param?.type == ParamType.chatbox) {
      final preview = step.text.length > 40 ? '${step.text.substring(0, 40)}…' : step.text;
      return 'Say "$preview", then wait ${_fmt(step.durationSeconds)}s';
    }
    if (step.durationSeconds <= 0) return 'Set "$label" to ${_fmt(step.targetValue)}';
    return 'Glide "$label" to ${_fmt(step.targetValue)} over ${_fmt(step.durationSeconds)}s';
  }

  String _fmt(double v) => v == v.roundToDouble() ? v.toStringAsFixed(0) : v.toStringAsFixed(2);

  // ---- parameter panel (mirrors the main screen's add/edit/automation) ----

  // owned by this sequence, not the parameter - never touches or enables
  // param.automation. runs (via the shared tick loop) for as long as this
  // sequence itself is enabled/running.
  Future<void> _openAutomationDialog(ParamControl param) async {
    final result = await showSequenceParamAutomationDialog(
      context,
      param,
      _parameters,
      seq.paramAutomations[param.name],
    );
    if (!result.changed) return;
    _update(() {
      if (result.automation == null) {
        seq.paramAutomations.remove(param.name);
      } else {
        seq.paramAutomations[param.name] = result.automation!;
      }
    });
  }

  Widget _automationButton(ParamControl param) {
    final auto = seq.paramAutomations[param.name];
    final configured = auto != null;
    // a step in this same sequence targeting the same parameter always wins
    // over this automation - the engine suppresses the automation's ticks
    // while that holds, rather than letting both send competing values.
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

  Future<void> _editParam(ParamControl param) async {
    final result = await showParamFormDialog(
      context,
      existing: param,
      takenNames: {for (final p in _parameters) p.name},
    );
    if (result == null) return;
    live.replaceParam(param, result);
  }

  Future<void> _deleteParam(ParamControl param) async {
    final ok = await confirmDialog(
      context,
      title: 'Delete parameter?',
      message: 'Remove "${param.label}" from this profile entirely (not just this sequence)?',
    );
    if (ok) live.removeParam(param);
  }

  Future<void> _showParamMenu(Offset globalPosition, ParamControl param) async {
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
        if (param.type != ParamType.custom) const PopupMenuItem(value: 'step', child: Text('Add a step for this')),
        if (param.isAutomatable) const PopupMenuItem(value: 'fetch', child: Text('Fetch value from VRChat')),
        const PopupMenuItem(value: 'delete', child: Text('Delete from profile')),
      ],
    );
    if (!mounted) return;
    switch (selected) {
      case 'delete':
        await _deleteParam(param);
      case 'edit':
        await _editParam(param);
      case 'step':
        final step = await _showStepDialog(
          context,
          SequenceStep(
            kind: SequenceStepKind.setValue,
            paramName: param.name,
            targetValue: live.sliderValue(param),
            targetBool: !live.toggleValue(param),
          ),
          _eligibleParams,
          isNew: true,
        );
        if (step != null) _update(() => seq.steps.add(step));
      case 'fetch':
        final value = await fetchLiveValue(
          context,
          param,
          developerMode: live.config.developerMode,
          timeout: Duration(seconds: live.config.oscQueryFetchTimeoutSeconds),
        );
        if (value != null) live.setLocalValue(param, value);
    }
  }

  Future<void> _discover() async {
    setState(() => _discovering = true);
    try {
      final result = await loadDiscovery(
        developerMode: live.config.developerMode,
        timeout: Duration(seconds: live.config.oscQueryFetchTimeoutSeconds),
      );
      if (!mounted) return;
      setState(() => _discovering = false);
      await showDiscoveryResultsSheet(
        context,
        result: result,
        noiseThreshold: live.config.liveParamNoiseThreshold,
        existingNames: {for (final p in _parameters) p.name},
        onAdd: live.addParam,
      );
    } catch (e) {
      if (mounted) await showErrorDialog(context, 'Discovery failed', e.toString());
    } finally {
      if (mounted) setState(() => _discovering = false);
    }
  }

  Future<void> _addParamManually() async {
    final control = await showParamFormDialog(context, takenNames: {for (final p in _parameters) p.name});
    if (control != null) live.addParam(control);
  }

  Widget _buildParametersSection(BuildContext context) {
    final params = _parameters;
    final query = _paramSearchQuery.toLowerCase();
    final filtered = query.isEmpty
        ? params
        : params.where((p) => p.label.toLowerCase().contains(query) || p.name.toLowerCase().contains(query)).toList();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            IconButton(
              icon: Icon(_showParams ? Icons.expand_more : Icons.chevron_right),
              onPressed: () => setState(() => _showParams = !_showParams),
            ),
            Expanded(child: Text('Parameters', style: Theme.of(context).textTheme.titleLarge)),
            IconButton(
              icon: const Icon(Icons.edit_note),
              tooltip: 'Add a parameter by hand',
              onPressed: _addParamManually,
            ),
            IconButton(
              icon: _discovering
                  ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.wifi_find),
              tooltip: 'Discover parameters from VRChat',
              onPressed: _discovering ? null : _discover,
            ),
          ],
        ),
        if (_showParams) ...[
          Text(
            'Automations set here belong to this sequence only - they run while it runs, separate from '
            'each parameter\'s own automation on the main screen.',
            style: Theme.of(context).textTheme.bodySmall,
          ),
          const SizedBox(height: 8),
          SearchBar(
            controller: _paramSearchController,
            hintText: 'Search parameters',
            leading: const Icon(Icons.search),
            elevation: const WidgetStatePropertyAll(0),
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
              child: Text('No parameters yet. Discover them from VRChat, or add one by hand.'),
            )
          else if (filtered.isEmpty)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 8),
              child: Text('No parameters match your search.'),
            )
          else
            for (final p in filtered)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: ParamCard(
                  key: ValueKey('seq-card:${p.name}'),
                  param: p,
                  live: live,
                  dense: true,
                  automationButton: p.isAutomatable ? _automationButton(p) : null,
                  onMenu: (pos) => _showParamMenu(pos, p),
                ),
              ),
        ],
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    // rebuilt on every live change, so the Running switch, the current-step
    // highlight and the parameter panel all track what's actually happening.
    return ListenableBuilder(
      listenable: live,
      builder: (context, _) => _buildPage(context),
    );
  }

  Widget _buildPage(BuildContext context) {
    final theme = Theme.of(context);
    final currentStep = seq.enabled ? live.sequenceEngine.currentStep(seq) : null;
    return Scaffold(
      appBar: AppBar(
        title: Text(seq.name),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 12),
            child: Row(
              children: [
                Text(seq.enabled ? 'Running' : 'Stopped'),
                const SizedBox(width: 8),
                Switch(value: seq.enabled, onChanged: (v) => _update(() => seq.enabled = v)),
              ],
            ),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _addStep,
        icon: const Icon(Icons.add),
        label: const Text('Add step'),
      ),
      body: Align(
        alignment: Alignment.topCenter,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 900),
          child: CustomScrollView(
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
                        onChanged: _renameSequence,
                      ),
                      const SizedBox(height: 12),
                      Row(
                        children: [
                          Expanded(
                            child: DropdownButtonFormField<SequenceRepeatMode>(
                              isExpanded: true,
                              initialValue: seq.repeatMode,
                              decoration: const InputDecoration(labelText: 'Repeat'),
                              items: const [
                                DropdownMenuItem(value: SequenceRepeatMode.once, child: Text('Once through')),
                                DropdownMenuItem(value: SequenceRepeatMode.loop, child: Text('Loop from step 1')),
                              ],
                              onChanged: (v) => _update(() => seq.repeatMode = v ?? SequenceRepeatMode.once),
                            ),
                          ),
                          if (seq.repeatMode == SequenceRepeatMode.loop) ...[
                            const SizedBox(width: 12),
                            Expanded(
                              child: TextField(
                                controller: _repeatCountController,
                                keyboardType: TextInputType.number,
                                decoration: const InputDecoration(labelText: 'Repeat count (0 = forever)'),
                                onSubmitted: _setRepeatCount,
                                onTapOutside: (_) {
                                  _setRepeatCount(_repeatCountController.text);
                                  FocusManager.instance.primaryFocus?.unfocus();
                                },
                              ),
                            ),
                          ],
                        ],
                      ),
                      const SizedBox(height: 8),
                      SwitchListTile(
                        contentPadding: EdgeInsets.zero,
                        title: const Text('Triggered by another parameter'),
                        value: _triggerEnabled,
                        onChanged: (v) => _update(() => _trigger().enabled = v),
                      ),
                      if (_triggerEnabled) ...[
                        TriggerFields(
                          eligibleParams: _watchableParams,
                          watchedParamName: _watchedParamName,
                          toggleCondition: _toggleCondition,
                          rangeCondition: _rangeCondition,
                          thresholdController: _triggerThreshold,
                          rangeMinController: _triggerRangeMin,
                          rangeMaxController: _triggerRangeMax,
                          requiredHitsController: _triggerRequiredHits,
                          onWatchedParamChanged: (name) => _update(() => _trigger().watchedParamName = name),
                          onToggleConditionChanged: (c) => _update(() => _trigger().toggleCondition = c),
                          onRangeConditionChanged: (c) => _update(() => _trigger().rangeCondition = c),
                          onThresholdChanged: _setTriggerThreshold,
                          onRangeMinChanged: _setTriggerRangeMin,
                          onRangeMaxChanged: _setTriggerRangeMax,
                          onRequiredHitsChanged: _setTriggerRequiredHits,
                        ),
                      ],
                      const SizedBox(height: 16),
                      Row(
                        children: [
                          Expanded(child: Text('Steps', style: theme.textTheme.titleLarge)),
                          Text(
                            seq.steps.isEmpty ? '' : '${seq.steps.length} steps  ·  drag to reorder',
                            style: theme.textTheme.bodySmall,
                          ),
                        ],
                      ),
                      const SizedBox(height: 4),
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
                    itemBuilder: (context, index) => _buildStep(context, index, index == currentStep),
                  ),
                ),
              SliverPadding(
                padding: const EdgeInsets.fromLTRB(16, 24, 16, 96),
                sliver: SliverToBoxAdapter(child: _buildParametersSection(context)),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildStep(BuildContext context, int index, bool current) {
    final step = seq.steps[index];
    final param = step.kind == SequenceStepKind.setValue ? _findEligible(step.paramName) : null;
    final scheme = Theme.of(context).colorScheme;
    return GestureDetector(
      key: ObjectKey(step),
      onSecondaryTapDown: (details) => _showStepContextMenu(context, details.globalPosition, index),
      child: Card(
        margin: const EdgeInsets.symmetric(vertical: 4),
        color: current ? scheme.secondaryContainer : null,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              ListTile(
                leading: ReorderableDragStartListener(
                  index: index,
                  child: Icon(current ? Icons.play_arrow : Icons.drag_handle, color: current ? scheme.primary : null),
                ),
                title: Text(
                  step.kind == SequenceStepKind.wait
                      ? '${index + 1}. Wait ${_fmt(step.durationSeconds)}s'
                      : '${index + 1}. ${_stepTitle(step)}',
                ),
                subtitle: step.kind == SequenceStepKind.setValue && param == null
                    ? Text('Target parameter "${step.paramName}" no longer exists - this step is skipped',
                        style: TextStyle(color: scheme.error))
                    : null,
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    IconButton(icon: const Icon(Icons.edit_outlined), onPressed: () => _editStep(index)),
                    IconButton(icon: const Icon(Icons.delete_outline), onPressed: () => _deleteStep(index)),
                  ],
                ),
              ),
              if (param != null && param.type == ParamType.slider)
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
                  child: Row(
                    children: [
                      Expanded(
                        child: Builder(builder: (context) {
                          final (lo, hi) = param.safeRange;
                          return Slider(
                            value: step.targetValue.clamp(lo, hi),
                            min: lo,
                            max: hi,
                            onChanged: (v) => setState(() => step.targetValue = v),
                            onChangeEnd: (_) => live.persist(),
                          );
                        }),
                      ),
                      SizedBox(width: 56, child: Text(_fmt(step.targetValue), textAlign: TextAlign.end)),
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
                      Switch(value: step.targetBool, onChanged: (v) => _update(() => step.targetBool = v)),
                    ],
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

Future<SequenceStep?> _showStepDialog(
  BuildContext context,
  SequenceStep? existing,
  List<ParamControl> eligibleParams, {
  bool isNew = false,
}) {
  return showDialog<SequenceStep>(
    context: context,
    builder: (context) => _StepDialog(existing: existing, eligibleParams: eligibleParams, isNew: isNew),
  );
}

class _StepDialog extends StatefulWidget {
  final SequenceStep? existing;
  final List<ParamControl> eligibleParams;
  final bool isNew;
  const _StepDialog({required this.existing, required this.eligibleParams, this.isNew = false});

  @override
  State<_StepDialog> createState() => _StepDialogState();
}

class _StepDialogState extends State<_StepDialog> {
  late SequenceStepKind _kind;
  late String? _paramName;
  late final TextEditingController _targetValue;
  late bool _targetBool;
  late final TextEditingController _duration;
  late final TextEditingController _text;
  String? _error;

  ParamControl? get _param => widget.eligibleParams.where((p) => p.name == _paramName).firstOrNull;

  @override
  void initState() {
    super.initState();
    final e = widget.existing;
    final params = widget.eligibleParams;
    // nothing to target yet - a wait step is still possible.
    _kind = params.isEmpty ? SequenceStepKind.wait : (e?.kind ?? SequenceStepKind.setValue);
    // a wait step (empty name) or a step whose target was deleted would
    // otherwise hand the dropdown a value it has no item for, which throws.
    _paramName = params.any((p) => p.name == e?.paramName) ? e!.paramName : params.firstOrNull?.name;
    _targetValue = TextEditingController(text: _fmt(e?.targetValue ?? _param?.max ?? 1.0));
    _targetBool = e?.targetBool ?? true;
    _duration = TextEditingController(text: _fmt(e?.durationSeconds ?? 1.0));
    _text = TextEditingController(text: e?.text ?? '');
  }

  String _fmt(double v) => v == v.roundToDouble() ? v.toStringAsFixed(0) : v.toString();

  @override
  void dispose() {
    _targetValue.dispose();
    _duration.dispose();
    _text.dispose();
    super.dispose();
  }

  void _save() {
    final param = _param;
    final duration = parseUserDouble(_duration.text);
    final target = parseUserDouble(_targetValue.text);
    String? error;
    if (duration == null || duration < 0) {
      error = 'Duration must be a number, 0 or more';
    } else if (_kind == SequenceStepKind.setValue && param == null) {
      error = 'Pick a parameter';
    } else if (_kind == SequenceStepKind.setValue &&
        param!.type == ParamType.slider &&
        target == null) {
      error = 'Target value must be a number';
    } else if (_kind == SequenceStepKind.setValue && param!.type == ParamType.chatbox && _text.text.trim().isEmpty) {
      error = 'Enter a message';
    }
    if (error != null) {
      setState(() => _error = error);
      return;
    }
    Navigator.of(context).pop(SequenceStep(
      kind: _kind,
      paramName: _kind == SequenceStepKind.setValue ? param!.name : '',
      targetValue: target ?? param?.max ?? 1.0,
      targetBool: _targetBool,
      durationSeconds: duration!,
      text: param?.type == ParamType.chatbox ? _text.text : '',
    ));
  }

  @override
  Widget build(BuildContext context) {
    final param = _param;
    final hasParams = widget.eligibleParams.isNotEmpty;
    return AlertDialog(
      title: Text(widget.existing == null || widget.isNew ? 'Add Step' : 'Edit Step'),
      content: SizedBox(
        width: 380,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            DropdownButtonFormField<SequenceStepKind>(
              isExpanded: true,
              initialValue: _kind,
              decoration: const InputDecoration(labelText: 'Step type'),
              items: [
                DropdownMenuItem(
                  value: SequenceStepKind.setValue,
                  enabled: hasParams,
                  child: Text(hasParams ? 'Set a parameter\'s value' : 'Set a value (add a parameter first)'),
                ),
                const DropdownMenuItem(value: SequenceStepKind.wait, child: Text('Wait')),
              ],
              onChanged: (v) => setState(() => _kind = v ?? _kind),
            ),
            if (_kind == SequenceStepKind.setValue) ...[
              const SizedBox(height: 8),
              DropdownButtonFormField<String>(
                initialValue: _paramName,
                isExpanded: true,
                decoration: const InputDecoration(labelText: 'Parameter'),
                items: [
                  for (final p in widget.eligibleParams)
                    DropdownMenuItem(value: p.name, child: Text(p.label, overflow: TextOverflow.ellipsis)),
                ],
                onChanged: (v) => setState(() => _paramName = v ?? _paramName),
              ),
              const SizedBox(height: 8),
              if (param?.type == ParamType.button)
                const SizedBox.shrink()
              else if (param?.type == ParamType.chatbox)
                TextField(
                  controller: _text,
                  maxLength: 144,
                  decoration: const InputDecoration(labelText: 'Message'),
                )
              else if (param?.type == ParamType.toggle)
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
                  decoration: InputDecoration(
                    labelText: 'Target value',
                    helperText: param == null ? null : 'Slider range ${_fmt(param.min)} to ${_fmt(param.max)}',
                  ),
                ),
              const SizedBox(height: 8),
              TextField(
                controller: _duration,
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                decoration: InputDecoration(
                  labelText: switch (param?.type) {
                    ParamType.toggle => 'Hold for (seconds)',
                    ParamType.button => 'Press for (seconds)',
                    ParamType.chatbox => 'Then wait (seconds)',
                    _ => 'Glide over (seconds)',
                  },
                  helperText: switch (param?.type) {
                    ParamType.toggle => 'Toggles snap instantly, then this step holds before advancing',
                    ParamType.button => 'Held down this long, then released (0 = a quick tap)',
                    ParamType.chatbox => 'VRChat rate-limits the chatbox, so leave a little time between messages',
                    _ => '0 = snap instantly (and run the next step right away)',
                  },
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
            if (_error != null) ...[
              const SizedBox(height: 8),
              Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
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
