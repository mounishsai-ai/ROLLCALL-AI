import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/screens/result_screen.dart';

/// The register is what a teacher signs their name to, so the things worth
/// pinning down are the ones that would change who gets marked present.
void main() {
  Map<String, dynamic> person(
    String reg,
    String name, {
    String resolvedBy = 'vector_match',
    double score = 0.82,
    String reason = '',
  }) =>
      {
        'reg_number': reg,
        'name': name,
        'resolved_by': resolvedBy,
        'score': score,
        'reason': reason,
      };

  final result = <String, dynamic>{
    'present': [
      person('10', 'TENTH'),
      person('2', 'SECOND'),
      person('1', 'FIRST'),
      person('7', 'RESCUED', resolvedBy: 'gemini_identify', score: 0.31),
    ],
    'unsure': [person('9', 'UNCERTAIN', resolvedBy: 'unresolved', score: 0.36)],
    'absent': [person('4', 'MISSING')],
    'unknown_faces': [
      {'face_id': 3, 'reason': 'Not any of the enrolled students.'}
    ],
  };

  Widget screen() => MaterialApp(home: ResultScreen(result: result));

  // The register is a long list and the default 800x600 test surface cuts it
  // off, so widgets further down are never built and cannot be found. Scoped to
  // the tester rather than the global dispatcher - a global override leaks into
  // every other test file in the suite.
  void tallSurface(WidgetTester tester) {
    tester.view.physicalSize = const Size(1200, 4000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
  }

  testWidgets('reg numbers read as numbers, so 2 comes before 10', (tester) async {
    tallSurface(tester);
    await tester.pumpWidget(screen());

    final second = tester.getTopLeft(find.text('SECOND')).dy;
    final tenth = tester.getTopLeft(find.text('TENTH')).dy;
    expect(second, lessThan(tenth),
        reason: 'sorted as text, "10" would sort before "2"');
  });

  testWidgets('everyone the system found starts ticked; nobody else does',
      (tester) async {
    tallSurface(tester);
    await tester.pumpWidget(screen());

    // Four present students are pre-ticked. The absent one and the unsure one
    // are not — the teacher opts them in deliberately.
    expect(find.text('CONFIRM REGISTER  ·  4 PRESENT'), findsOneWidget);
  });

  testWidgets('the teacher can overrule the system in one tap', (tester) async {
    tallSurface(tester);
    await tester.pumpWidget(screen());

    await tester.tap(find.text('MISSING'));
    await tester.pumpAndSettle();
    expect(find.text('CONFIRM REGISTER  ·  5 PRESENT'), findsOneWidget,
        reason: 'ticking an absent student adds them');

    await tester.tap(find.text('FIRST'));
    await tester.pumpAndSettle();
    expect(find.text('CONFIRM REGISTER  ·  4 PRESENT'), findsOneWidget,
        reason: 'unticking a present student removes them');
  });

  testWidgets('a student the maths could not place is flagged for a new photo',
      (tester) async {
    tallSurface(tester);
    await tester.pumpWidget(screen());

    // RESCUED needed Gemini; a confident vector match must not be flagged.
    expect(find.text('TIME FOR A NEW PHOTO'), findsWidgets);
    expect(find.textContaining('could not place them'), findsOneWidget);
  });

  testWidgets('verdicts are grouped by how they were reached', (tester) async {
    tallSurface(tester);
    await tester.pumpWidget(screen());

    expect(find.text('MATCHED INSTANTLY'), findsOneWidget);
    expect(find.text('THE SYSTEM WORKED THESE OUT'), findsOneWidget);
    expect(find.text('LEFT FOR YOU'), findsOneWidget);
    expect(find.text('NOT ON THE ROSTER'), findsOneWidget);
    expect(find.text('NOT FOUND IN THE PHOTO'), findsOneWidget);
  });
}
