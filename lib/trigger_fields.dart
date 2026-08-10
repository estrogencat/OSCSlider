import 'package:flutter/material.dart';

import 'param_control.dart';

/// the watched-parameter picker + condition-specific fields shared by the
/// automation dialog and the sequence editor. purely presentational - the
/// caller owns all state and controllers, since the two callers persist
/// changes differently (save button vs. mutate-immediately).
class TriggerFields extends StatelessWidget {
  final List<ParamControl> eligibleParams;
  final String? watchedParamName;
  final ToggleTriggerCondition toggleCondition;
  final RangeTriggerCondition rangeCondition;
  final TextEditingController thresholdController;
  final TextEditingController rangeMinController;
  final TextEditingController rangeMaxController;
  final TextEditingController requiredHitsController;
  final ValueChanged<String> onWatchedParamChanged;
  final ValueChanged<ToggleTriggerCondition> onToggleConditionChanged;
  final ValueChanged<RangeTriggerCondition> onRangeConditionChanged;
  // only needed by callers with no separate Save button (the sequence
  // editor) - the automation dialog just reads the controllers at save time.
  final ValueChanged<String>? onThresholdChanged;
  final ValueChanged<String>? onRangeMinChanged;
  final ValueChanged<String>? onRangeMaxChanged;
  final ValueChanged<String>? onRequiredHitsChanged;

  const TriggerFields({
    super.key,
    required this.eligibleParams,
    required this.watchedParamName,
    required this.toggleCondition,
    required this.rangeCondition,
    required this.thresholdController,
    required this.rangeMinController,
    required this.rangeMaxController,
    required this.requiredHitsController,
    required this.onWatchedParamChanged,
    required this.onToggleConditionChanged,
    required this.onRangeConditionChanged,
    this.onThresholdChanged,
    this.onRangeMinChanged,
    this.onRangeMaxChanged,
    this.onRequiredHitsChanged,
  });

  @override
  Widget build(BuildContext context) {
    if (eligibleParams.isEmpty) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 8),
        child: Text('No other slider/toggle parameters to watch yet.'),
      );
    }
    final watched = _findByName(eligibleParams, watchedParamName) ?? eligibleParams.first;
    final isPulseCondition = watched.type == ParamType.toggle
        ? (toggleCondition == ToggleTriggerCondition.turnsOn || toggleCondition == ToggleTriggerCondition.turnsOff)
        : (rangeCondition == RangeTriggerCondition.crossesAbove ||
            rangeCondition == RangeTriggerCondition.crossesBelow);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        DropdownButtonFormField<String>(
          initialValue: watched.name,
          decoration: const InputDecoration(labelText: 'Watch parameter'),
          items: [
            for (final p in eligibleParams) DropdownMenuItem(value: p.name, child: Text(p.label)),
          ],
          onChanged: (v) => onWatchedParamChanged(v ?? watched.name),
        ),
        const SizedBox(height: 8),
        if (watched.type == ParamType.toggle) ...[
          DropdownButtonFormField<ToggleTriggerCondition>(
            initialValue: toggleCondition,
            decoration: const InputDecoration(labelText: 'Condition'),
            items: const [
              DropdownMenuItem(value: ToggleTriggerCondition.turnsOn, child: Text('Turns on (fires once)')),
              DropdownMenuItem(value: ToggleTriggerCondition.turnsOff, child: Text('Turns off (fires once)')),
              DropdownMenuItem(value: ToggleTriggerCondition.whileOn, child: Text('While on (holds)')),
              DropdownMenuItem(value: ToggleTriggerCondition.whileOff, child: Text('While off (holds)')),
            ],
            onChanged: (v) => onToggleConditionChanged(v ?? toggleCondition),
          ),
          if (isPulseCondition) ...[
            const SizedBox(height: 8),
            _buildRequiredHits(),
          ],
        ] else ...[
          DropdownButtonFormField<RangeTriggerCondition>(
            initialValue: rangeCondition,
            decoration: const InputDecoration(labelText: 'Condition'),
            items: const [
              DropdownMenuItem(value: RangeTriggerCondition.above, child: Text('Above threshold (holds)')),
              DropdownMenuItem(value: RangeTriggerCondition.below, child: Text('Below threshold (holds)')),
              DropdownMenuItem(
                  value: RangeTriggerCondition.crossesAbove, child: Text('Crosses above threshold (fires once)')),
              DropdownMenuItem(
                  value: RangeTriggerCondition.crossesBelow, child: Text('Crosses below threshold (fires once)')),
              DropdownMenuItem(value: RangeTriggerCondition.inRange, child: Text('Inside range (holds)')),
              DropdownMenuItem(value: RangeTriggerCondition.outOfRange, child: Text('Outside range (holds)')),
            ],
            onChanged: (v) => onRangeConditionChanged(v ?? rangeCondition),
          ),
          const SizedBox(height: 8),
          if (rangeCondition == RangeTriggerCondition.above ||
              rangeCondition == RangeTriggerCondition.below ||
              rangeCondition == RangeTriggerCondition.crossesAbove ||
              rangeCondition == RangeTriggerCondition.crossesBelow)
            TextField(
              controller: thresholdController,
              keyboardType: const TextInputType.numberWithOptions(signed: true, decimal: true),
              decoration: const InputDecoration(labelText: 'Threshold'),
              onSubmitted: onThresholdChanged,
              onTapOutside: onThresholdChanged == null ? null : (_) => onThresholdChanged!(thresholdController.text),
            )
          else
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: rangeMinController,
                    keyboardType: const TextInputType.numberWithOptions(signed: true, decimal: true),
                    decoration: const InputDecoration(labelText: 'Range min'),
                    onSubmitted: onRangeMinChanged,
                    onTapOutside:
                        onRangeMinChanged == null ? null : (_) => onRangeMinChanged!(rangeMinController.text),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: TextField(
                    controller: rangeMaxController,
                    keyboardType: const TextInputType.numberWithOptions(signed: true, decimal: true),
                    decoration: const InputDecoration(labelText: 'Range max'),
                    onSubmitted: onRangeMaxChanged,
                    onTapOutside:
                        onRangeMaxChanged == null ? null : (_) => onRangeMaxChanged!(rangeMaxController.text),
                  ),
                ),
              ],
            ),
          if (isPulseCondition) ...[
            const SizedBox(height: 8),
            _buildRequiredHits(),
          ],
        ],
      ],
    );
  }

  Widget _buildRequiredHits() {
    return TextField(
      controller: requiredHitsController,
      keyboardType: TextInputType.number,
      decoration: const InputDecoration(
        labelText: 'Activations needed',
        helperText: 'Fires after this many activations (1 = every time)',
      ),
      onSubmitted: onRequiredHitsChanged,
      onTapOutside:
          onRequiredHitsChanged == null ? null : (_) => onRequiredHitsChanged!(requiredHitsController.text),
    );
  }
}

ParamControl? _findByName(List<ParamControl> params, String? name) {
  for (final p in params) {
    if (p.name == name) return p;
  }
  return null;
}
