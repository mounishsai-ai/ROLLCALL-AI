import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/main.dart';

void main() {
  // These drive HomeScreen directly rather than AttendanceApp. The app opens
  // on the splash screen, which navigates on a timer, and a pending timer
  // fails the test regardless of what is being asserted.
  Widget home() => const MaterialApp(home: HomeScreen());

  // The home screen is a lazy ListView, so anything below the fold is never
  // built and `find.text` reports it missing. The default 800x600 test window
  // is shorter than a phone; give it room so the whole screen is real.
  void useTallScreen(WidgetTester tester) {
    tester.view.physicalSize = const Size(1200, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
  }

  testWidgets('the home screen offers the two things the app does',
      (tester) async {
    useTallScreen(tester);
    await tester.pumpWidget(home());

    expect(find.text('Mark attendance'), findsOneWidget);
    expect(find.text('Manage students'), findsOneWidget);
  });

  testWidgets('the server address and access key can be changed from the home screen',
      (tester) async {
    useTallScreen(tester);
    await tester.pumpWidget(home());

    await tester.tap(find.byIcon(Icons.tune_rounded));
    await tester.pumpAndSettle();

    expect(find.text('SERVER'), findsOneWidget);
    // Two fields: where the backend is, and the key it expects. The key is a
    // separate box rather than part of the URL so it can be cleared on its own
    // when pointing at a local backend that has none.
    expect(find.byType(TextField), findsNWidgets(2));
  });

  testWidgets('a missing access key is announced before anything fails',
      (tester) async {
    useTallScreen(tester);
    await tester.pumpWidget(home());

    // No key is configured in a test, so the notice stands in for the 401 the
    // first tap would otherwise produce.
    expect(find.text('ACCESS KEY NEEDED'), findsOneWidget);
  });

  testWidgets('tapping Manage students opens the roster', (tester) async {
    useTallScreen(tester);
    await tester.pumpWidget(home());

    await tester.tap(find.text('Manage students'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    // The roster loads over the network, which fails in a test; what matters
    // here is that the navigation happened and the screen came up.
    expect(find.text('THE ROSTER'), findsOneWidget);
  });
}
