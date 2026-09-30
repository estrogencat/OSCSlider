import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:osc_slider/app_updater.dart';
import 'package:osc_slider/config_store.dart';
import 'package:osc_slider/live_controller.dart';
import 'package:osc_slider/main.dart';
import 'package:osc_slider/param_control.dart';
import 'package:osc_slider/update_dialog.dart';

// phone portrait, and a small desktop window.
const _sizes = [Size(360, 740), Size(520, 480)];

// real fonts when the SDK has them - the test font's square glyphs are much
// wider than Roboto and would flag layouts that are actually fine.
Future<void> _loadFonts() async {
  final root = Platform.environment['FLUTTER_ROOT'];
  if (root == null) return;
  final dir = '$root/bin/cache/artifacts/material_fonts';
  Future<void> load(String family, List<String> files) async {
    final loader = FontLoader(family);
    for (final f in files) {
      final file = File('$dir/$f');
      if (!file.existsSync()) return;
      loader.addFont(Future.value(ByteData.sublistView(file.readAsBytesSync())));
    }
    await loader.load();
  }

  await load('Roboto', ['Roboto-Regular.ttf', 'Roboto-Medium.ttf']);
  await load('MaterialIcons', ['MaterialIcons-Regular.otf']);
}

AppConfig _config() => AppConfig(host: '192.168.1.20', port: 9000, parameters: [
      ParamControl(name: 'Ears', label: 'Ears', type: ParamType.toggle, category: 'Body'),
      ParamControl(name: 'HairHue', label: 'Hair hue with a fairly long label', type: ParamType.slider),
      ParamControl(name: 'Outfit', label: 'Outfit', type: ParamType.slider, numericKind: NumericKind.int, max: 3),
      ParamControl(name: '/input/Jump', label: 'Jump', type: ParamType.button),
      ParamControl(name: '/chatbox/input', label: 'Chatbox', type: ParamType.chatbox, customValueText: ''),
      ParamControl(name: 'Color', label: 'Colour', type: ParamType.custom, customTypeTag: 'r', customValueText: 'ff00ffff'),
    ])
      ..sequences.add(AutomationSequence(id: 's1', name: 'Wave', steps: [
        SequenceStep(kind: SequenceStepKind.setValue, paramName: 'Ears', targetBool: true),
        SequenceStep(kind: SequenceStepKind.wait, durationSeconds: 2),
        SequenceStep(kind: SequenceStepKind.setValue, paramName: 'HairHue', targetValue: 0.5, durationSeconds: 1),
      ]));

Future<void> _pump(WidgetTester tester, Size size) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(MaterialApp(
    theme: buildAppTheme(ColorScheme.fromSeed(seedColor: Colors.deepPurple)),
    home: HomePage(startServices: false, initialConfig: _config()),
  ));
  await tester.pump();
}

Future<void> _tapTooltip(WidgetTester tester, String tooltip) async {
  await tester.tap(find.byTooltip(tooltip).first);
  await tester.pumpAndSettle();
}

Future<void> _scrollThrough(WidgetTester tester) async {
  final scrollables = find.byType(Scrollable);
  if (scrollables.evaluate().isEmpty) return;
  for (var i = 0; i < 12; i++) {
    await tester.drag(scrollables.first, const Offset(0, -300), warnIfMissed: false);
    await tester.pumpAndSettle();
  }
}

Future<void> _back(WidgetTester tester) async {
  await tester.pageBack();
  await tester.pumpAndSettle();
}

void main() {
  late Directory dir;
  setUpAll(() async {
    await _loadFonts();
    dir = await Directory.systemTemp.createTemp('oscslider_narrow');
    ConfigStore.directoryOverride = dir.path;
  });
  tearDownAll(() async {
    ConfigStore.directoryOverride = null;
    await dir.delete(recursive: true);
  });

  for (final size in _sizes) {
    final label = '${size.width.toInt()}x${size.height.toInt()}';

    testWidgets('main screen fits at $label', (tester) async {
      await _pump(tester, size);
      await _scrollThrough(tester);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('settings fits at $label', (tester) async {
      await _pump(tester, size);
      await _tapTooltip(tester, 'Settings');
      await _scrollThrough(tester);
      await _back(tester);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('sequences fit at $label', (tester) async {
      await _pump(tester, size);
      if (find.byTooltip('Sequences').evaluate().isNotEmpty) {
        await _tapTooltip(tester, 'Sequences');
      } else {
        // narrow: it's in the ⋮ menu.
        await tester.tap(find.descendant(of: find.byType(AppBar), matching: find.byTooltip('More')).first);
        await tester.pumpAndSettle();
        await tester.tap(find.text('Sequences'));
        await tester.pumpAndSettle();
      }
      await tester.tap(find.text('Wave').first);
      await tester.pumpAndSettle();
      await _scrollThrough(tester);
      await _back(tester);
      await _back(tester);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('parameter dialogs fit at $label', (tester) async {
      await _pump(tester, size);
      for (final name in ['Ears', 'Outfit', 'Jump', 'Chatbox', 'Colour']) {
        await _openCardMenu(tester, name);
        await tester.tap(find.text('Edit'));
        await tester.pumpAndSettle();
        await _scrollThrough(tester);
        await tester.tap(find.text('Cancel'));
        await tester.pumpAndSettle();
      }
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('automation dialog fits at $label', (tester) async {
      await _pump(tester, size);
      await _openCardMenu(tester, 'Outfit');
      await tester.tap(find.text('Automation...'));
      await tester.pumpAndSettle();
      await _scrollThrough(tester);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('add parameter and update dialogs fit at $label', (tester) async {
      await _pump(tester, size);
      await tester.tap(find.text('Add parameter'));
      await tester.pumpAndSettle();
      await _scrollThrough(tester);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();

      final context = tester.element(find.byType(Scaffold).first);
      final live = LiveController(_config());
      showUpdateDialog(
        context,
        info: UpdateInfo(
          version: '9.9.9',
          notes: '## Big update\n- one thing that is quite long and wraps around\n- another\n\n| a | b |',
          pageUrl: Uri(),
        ),
        currentVersion: '2.0.0',
        live: live,
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Later'));
      await tester.pumpAndSettle();
      live.dispose();
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('tour fits at $label', (tester) async {
      await _pump(tester, size);
      await tester.tap(find.descendant(of: find.byType(AppBar), matching: find.byTooltip('More')).first);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Show the tour'));
      await tester.pumpAndSettle();
      for (var i = 0; i < 15 && find.text('Done').evaluate().isEmpty; i++) {
        await tester.tap(find.text(i == 0 ? 'Show me around' : 'Next'));
        await tester.pumpAndSettle();
      }
      await tester.tap(find.text('Done'));
      await tester.pumpAndSettle();
      await tester.pumpWidget(const SizedBox());
    });
  }
}

Future<void> _openCardMenu(WidgetTester tester, String label) async {
  // cards far down the list aren't built until they're scrolled near.
  final list = find.descendant(of: find.byType(ListView), matching: find.byType(Scrollable)).first;
  await tester.drag(list, const Offset(0, 5000));
  await tester.pumpAndSettle();
  await tester.scrollUntilVisible(find.text(label), 200, scrollable: list);
  final more = find.descendant(
    of: find.ancestor(of: find.text(label), matching: find.byType(Card)).first,
    matching: find.byTooltip('More'),
  );
  await tester.ensureVisible(more);
  await tester.pumpAndSettle();
  await tester.tap(more);
  await tester.pumpAndSettle();
}
