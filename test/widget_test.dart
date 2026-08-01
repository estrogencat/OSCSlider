import 'package:flutter_test/flutter_test.dart';

import 'package:osc_slider/main.dart';

void main() {
  testWidgets('app renders without crashing', (WidgetTester tester) async {
    await tester.pumpWidget(const OscSliderApp());
    await tester.pump();
    expect(find.text('OSCSlider'), findsOneWidget);
  });
}
