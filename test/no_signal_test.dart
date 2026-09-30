import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:osc_slider/config_store.dart';
import 'package:osc_slider/main.dart';
import 'package:osc_slider/no_signal.dart';
import 'package:osc_slider/param_control.dart';

Future<void> _pump(WidgetTester tester) async {
  tester.view.physicalSize = const Size(1280, 800);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(MaterialApp(
    navigatorKey: appNavigatorKey,
    home: HomePage(
      startServices: false,
      initialConfig: AppConfig(host: '127.0.0.1', port: 9000, parameters: [
        ParamControl(name: 'Hue', label: 'Hue', type: ParamType.slider),
      ]),
    ),
  ));
  await tester.pump();
}

Future<void> _type(WidgetTester tester, String text) async {
  for (final c in text.split('')) {
    final key = LogicalKeyboardKey(c.toLowerCase().codeUnitAt(0));
    await tester.sendKeyDownEvent(key, character: c);
    await tester.sendKeyUpEvent(key);
  }
  await tester.pumpAndSettle();
}

void main() {
  late Directory dir;
  setUpAll(() async {
    NoSignal.soundEnabled = false;
    HardwareKeyboard.instance.addHandler(NoSignal.handleKey);
    dir = await Directory.systemTemp.createTemp('oscslider_nosignal');
    ConfigStore.directoryOverride = dir.path;
  });
  tearDownAll(() async {
    HardwareKeyboard.instance.removeHandler(NoSignal.handleKey);
    ConfigStore.directoryOverride = null;
    await dir.delete(recursive: true);
  });

  testWidgets('typing nosignal opens the page, in any case, and Esc closes it', (tester) async {
    await _pump(tester);
    await _type(tester, 'xxNoSiGnAl');
    expect(find.text('无信号'), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.text('无信号'), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('typing it into a text field does nothing', (tester) async {
    await _pump(tester);
    await tester.tap(find.byType(SearchBar));
    await tester.pump();
    await _type(tester, 'nosignal');
    expect(find.text('无信号'), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('holding the version number for 10 seconds opens it', (tester) async {
    await _pump(tester);
    await tester.tap(find.byTooltip('Settings'));
    await tester.pumpAndSettle();
    final version = find.byType(NoSignalHold);
    await tester.scrollUntilVisible(version, 300, scrollable: find.byType(Scrollable).first);
    // a short hold does nothing.
    var gesture = await tester.startGesture(tester.getCenter(version));
    await tester.pump(const Duration(seconds: 3));
    await gesture.up();
    await tester.pump(const Duration(seconds: 8));
    expect(find.text('无信号'), findsNothing);
    gesture = await tester.startGesture(tester.getCenter(version));
    await tester.pump(const Duration(seconds: 10));
    await gesture.up();
    await tester.pumpAndSettle();
    expect(find.text('无信号'), findsOneWidget);
    await tester.tap(find.byTooltip('Back'));
    await tester.pumpAndSettle();
    expect(find.text('无信号'), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });
}
