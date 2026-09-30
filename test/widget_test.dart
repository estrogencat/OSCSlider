import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:osc_slider/config_store.dart';
import 'package:osc_slider/main.dart';
import 'package:osc_slider/osc_input_hub.dart';
import 'package:osc_slider/osc_listener.dart';
import 'package:osc_slider/param_control.dart';
import 'package:osc_slider/param_form_dialog.dart';

AppConfig _config() => AppConfig(
  host: '127.0.0.1',
  port: 9000,
  parameters: [
    ParamControl(name: 'Ears', label: 'Ears', type: ParamType.toggle),
    ParamControl(name: 'Hue', label: 'Hue', type: ParamType.slider),
    ParamControl(name: 'Outfit', label: 'Outfit', type: ParamType.slider, numericKind: NumericKind.int, max: 3),
  ],
);

Future<void> _pump(WidgetTester tester, AppConfig config) async {
  tester.view.physicalSize = const Size(1280, 800);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(MaterialApp(home: HomePage(startServices: false, initialConfig: config)));
  await tester.pump();
}

void main() {
  late Directory dir;
  setUpAll(() async {
    dir = await Directory.systemTemp.createTemp('oscslider_widget');
    ConfigStore.directoryOverride = dir.path;
  });
  tearDownAll(() async {
    ConfigStore.directoryOverride = null;
    await dir.delete(recursive: true);
  });

  testWidgets('renders the active profile and its parameters', (tester) async {
    await _pump(tester, _config());
    expect(find.text('Default'), findsOneWidget);
    expect(find.text('Ears'), findsOneWidget);
    expect(find.text('Hue'), findsOneWidget);
    expect(find.text('Add parameter'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('tapping a toggle card flips it', (tester) async {
    final config = _config();
    await _pump(tester, config);
    expect(tester.widget<Switch>(find.byType(Switch)).value, false);
    await tester.tap(find.text('Ears'));
    await tester.pump();
    expect(tester.widget<Switch>(find.byType(Switch)).value, true);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('values VRChat reports show up on the dashboard', (tester) async {
    await _pump(tester, _config());
    oscInputHub.debugInject(OscMessage('/avatar/parameters/Ears', [true]));
    oscInputHub.debugInject(OscMessage('/avatar/parameters/Hue', [0.75]));
    await tester.pump(const Duration(milliseconds: 50));
    expect(tester.widget<Switch>(find.byType(Switch)).value, true);
    expect(find.text('0.750'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('int sliders snap to whole steps and show whole numbers', (tester) async {
    await _pump(tester, _config());
    final slider = tester.widgetList<Slider>(find.byType(Slider)).last;
    expect(slider.divisions, 3);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('editing a parameter keeps its automation and refuses duplicate names', (tester) async {
    final param = ParamControl(
      name: 'Hue',
      label: 'Hue',
      type: ParamType.slider,
      automation: Automation(enabled: true),
      schedule: ParamSchedule(),
    );
    ParamControl? result;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () async =>
                result = await showParamFormDialog(context, existing: param, takenNames: {'Hue', 'Ears'}),
            child: const Text('open'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    // renaming onto another parameter's address is refused.
    await tester.enterText(find.widgetWithText(TextField, 'OSC address'), 'Ears');
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    expect(result, isNull);
    expect(find.textContaining('already a parameter'), findsOneWidget);
    await tester.enterText(find.widgetWithText(TextField, 'OSC address'), '/avatar/parameters/Hue2');
    await tester.enterText(find.widgetWithText(TextField, 'Display label (optional)'), 'Color');
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    expect(result!.name, 'Hue2', reason: 'the full VRChat path is normalized to the short name');
    expect(result!.label, 'Color');
    expect(result!.automation, same(param.automation));
    expect(result!.schedule, same(param.schedule));
  });

  testWidgets('empty profile shows a way to add parameters', (tester) async {
    await _pump(tester, AppConfig(host: '127.0.0.1', port: 9000, parameters: []));
    expect(find.text('Discover from VRChat'), findsOneWidget);
    expect(find.text('Add by hand'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('the tour walks through the buttons and can be skipped', (tester) async {
    final config = _config()..tutorialSeen = false;
    await _pump(tester, config);
    await tester.tap(find.descendant(of: find.byType(AppBar), matching: find.byTooltip('More')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Show the tour'));
    await tester.pumpAndSettle();
    expect(find.text('Welcome to OSCSlider!'), findsOneWidget);
    await tester.tap(find.text('Show me around'));
    await tester.pumpAndSettle();
    expect(find.text('Connection'), findsOneWidget);
    await tester.tap(find.text('Next'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Next'));
    await tester.pumpAndSettle();
    // the card step, since there are parameters.
    expect(find.text('Controls'), findsOneWidget);
    await tester.tap(find.text('Back'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Find your avatar'), findsOneWidget);
    await tester.tap(find.text('Skip tour'));
    await tester.pumpAndSettle();
    expect(find.text('Skip tour'), findsNothing);
    expect(config.tutorialSeen, true);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('the tour skips card steps on an empty profile and ends with Done', (tester) async {
    await _pump(tester, AppConfig(host: '127.0.0.1', port: 9000));
    await tester.tap(find.descendant(of: find.byType(AppBar), matching: find.byTooltip('More')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Show the tour'));
    await tester.pumpAndSettle();
    final titles = <String>[];
    for (var i = 0; i < 20 && find.text('Done').evaluate().isEmpty; i++) {
      await tester.tap(find.text(i == 0 ? 'Show me around' : 'Next'));
      await tester.pumpAndSettle();
      for (final t in ['Controls', 'Make it move by itself', 'Add your own']) {
        if (find.text(t).evaluate().isNotEmpty) titles.add(t);
      }
    }
    // the empty screen's own add button is still pointed out.
    expect(titles, ['Add your own']);
    await tester.tap(find.text('Done'));
    await tester.pumpAndSettle();
    expect(find.text('Done'), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });
}
