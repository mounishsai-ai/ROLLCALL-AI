import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/main.dart';

void main() {
  // These drive HomeScreen directly rather than AttendanceApp. The app opens
  // on the splash screen, which navigates on a timer, and a pending timer
  // fails the test regardless of what is being asserted.
  Widget home() => const MaterialApp(home: HomeScreen());

  testWidgets('the home screen offers the two things the app does',
      (tester) async {
    await tester.pumpWidget(home());

    expect(find.text('Mark attendance'), findsOneWidget);
    expect(find.text('Manage students'), findsOneWidget);
  });

  testWidgets('the server address can be changed from the home screen',
      (tester) async {
    await tester.pumpWidget(home());

    await tester.tap(find.byIcon(Icons.tune_rounded));
    await tester.pumpAndSettle();

    expect(find.text('SERVER ADDRESS'), findsOneWidget);
    expect(find.byType(TextField), findsOneWidget);
  });

  testWidgets('tapping Manage students opens the roster', (tester) async {
    await tester.pumpWidget(home());

    await tester.tap(find.text('Manage students'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    // The roster loads over the network, which fails in a test; what matters
    // here is that the navigation happened and the screen came up.
    expect(find.text('THE ROSTER'), findsOneWidget);
  });
}
