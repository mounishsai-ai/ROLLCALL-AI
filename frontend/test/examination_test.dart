import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/models/scan_event.dart';
import 'package:frontend/screens/result_screen.dart';
import 'package:frontend/screens/scan_screen.dart';

/// A 1x1 JPEG, so thumbnail decoding is exercised with something real.
const _jpegBase64 =
    '/9j/4AAQSkZJRgABAQEAYABgAAD/2wBDAAgGBgcGBQgHBwcJCQgKDBQNDAsLDBkSEw8UHRofHh0a'
    'HBwgJC4nICIsIxwcKDcpLDAxNDQ0Hyc5PTgyPC4zNDL/wAALCAABAAEBAREA/8QAFAABAAAAAAAA'
    'AAAAAAAAAAAACf/EABQQAQAAAAAAAAAAAAAAAAAAAAD/2gAIAQEAAD8AKp//2Q==';

void main() {
  group('ScanEvent parsing', () {
    test('reads a face observation, thumbnail included', () {
      final event = ScanEvent.fromJson({
        'seq': 3,
        'ts': 8.46,
        'kind': 'observe',
        'title': 'Looking closer at face #3',
        'detail': 'Closest match is MAHESH BABU at 81% similarity.',
        'face_id': 2,
        'thumb': _jpegBase64,
      });

      expect(event.faceId, 2);
      expect(event.kind, 'observe');
      expect(event.thumb, isNotNull);
      expect(event.corrected, isFalse);
    });

    test('a broken thumbnail does not lose the reasoning', () {
      final event = ScanEvent.fromJson({
        'kind': 'observe',
        'title': 'Looking closer',
        'thumb': 'not-valid-base64!!!',
      });
      expect(event.thumb, isNull);
      expect(event.title, 'Looking closer');
    });

    test('missing fields fall back rather than throwing', () {
      final event = ScanEvent.fromJson({});
      expect(event.kind, 'status');
      expect(event.faceId, isNull);
      expect(event.detail, '');
    });
  });

  group('ScanProgress', () {
    test('groups interleaved events into one thread per face', () {
      final progress = ScanProgress();
      progress.ingest([
        ScanEvent.fromJson({'seq': 0, 'kind': 'status', 'title': '7 faces found'}),
        ScanEvent.fromJson({'seq': 1, 'kind': 'observe', 'face_id': 2, 'title': 'a'}),
        ScanEvent.fromJson({'seq': 2, 'kind': 'observe', 'face_id': 3, 'title': 'b'}),
        ScanEvent.fromJson({'seq': 3, 'kind': 'think', 'face_id': 2, 'title': 'c'}),
        ScanEvent.fromJson({
          'seq': 4,
          'kind': 'verdict',
          'face_id': 2,
          'title': 'present',
          'outcome': 'present',
        }),
      ]);

      expect(progress.scanNotes.length, 1);
      expect(progress.cases.length, 2);
      expect(progress.cases[2]!.steps.length, 3);
      expect(progress.cases[2]!.state, 'present');
      expect(progress.cases[3]!.isWorking, isTrue);
      expect(progress.settledCount, 1);
      expect(progress.openCount, 1);
    });

    test('two faces guessing the same student stay separate threads', () {
      final progress = ScanProgress();
      progress.ingest([
        ScanEvent.fromJson({'kind': 'observe', 'face_id': 0, 'title': 'closest is Ram'}),
        ScanEvent.fromJson({'kind': 'observe', 'face_id': 1, 'title': 'closest is Ram'}),
      ]);
      expect(progress.cases.length, 2);
    });
  });

  group('The register', () {
    // Shape taken from a real adjudicated scan.
    final result = {
      'present': [
        {
          'name': 'PAWAN KALYAN',
          'reg_number': '1',
          'vlm_verified': false,
          'resolved_by': 'vector_match',
          'reason': 'Matched at 94% similarity, clear of the runner-up.',
        },
        {
          'name': 'RAM CHARAN',
          'reg_number': '3',
          'vlm_verified': true,
          'resolved_by': 'gemini_identify',
          'corrected': true,
          'reason': 'The facial features, beard shape, and eye structure match.',
        },
      ],
      'unsure': <Map<String, dynamic>>[],
      'absent': [
        {'name': 'NTR', 'reg_number': '7', 'vlm_verified': false},
      ],
      'unknown_faces': [
        {'face_id': 5, 'reason': 'Does not match any enrolled student.'},
      ],
      'processing': {'status': 'success', 'error': null},
      'recognized_count': 2,
      'unsure_count': 0,
    };

    testWidgets('renders every section and the reasoning behind each name',
        (tester) async {
      // The register scrolls, and a lazy list never builds what is below the
      // fold. Give the test a window tall enough to hold the whole page.
      tester.view.physicalSize = const Size(1000, 3000);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      await tester.pumpWidget(MaterialApp(home: ResultScreen(result: result)));
      await tester.pumpAndSettle();

      expect(find.text('PAWAN KALYAN'), findsOneWidget);
      expect(find.text('RAM CHARAN'), findsOneWidget);
      // Sections say HOW each verdict was reached, not just what it was: a
      // teacher signing this off is entitled to know which names the maths
      // settled and which ones needed a closer look.
      expect(find.text('MATCHED INSTANTLY'), findsOneWidget);
      expect(find.text('THE SYSTEM WORKED THESE OUT'), findsOneWidget);
      expect(find.text('NOT FOUND IN THE PHOTO'), findsOneWidget);
      // A face belonging to nobody enrolled must be reported, not dropped.
      expect(find.text('NOT ON THE ROSTER'), findsOneWidget);
      expect(find.text('CORRECTED THE FIRST GUESS'), findsOneWidget);
      // The reasoning travels with the name.
      expect(find.textContaining('beard shape'), findsOneWidget);
    });

    testWidgets('survives a result with nothing in it', (tester) async {
      await tester.pumpWidget(const MaterialApp(home: ResultScreen(result: {})));
      await tester.pumpAndSettle();
      expect(find.text('THE REGISTER'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });

  group('The reasoning trace', () {
    /// Events copied from a real adjudicated scan, covering every branch the
    /// layout has to render: a thumbnail, a re-crop result, a correction, a
    /// failed check, and a "not enrolled" verdict.
    ScanProgress buildProgress() {
      final progress = ScanProgress();
      progress.ingest([
        ScanEvent.fromJson({
          'seq': 0,
          'ts': 0.0,
          'kind': 'status',
          'title': 'Scanning the photo for faces',
          'detail': 'Detecting every face, then measuring each one.',
        }),
        ScanEvent.fromJson({
          'seq': 1,
          'ts': 8.46,
          'kind': 'status',
          'title': '7 faces found — 3 matched immediately',
          'detail': '4 faces are not clear-cut.',
        }),
        ScanEvent.fromJson({
          'seq': 2,
          'ts': 8.5,
          'kind': 'observe',
          'face_id': 2,
          'title': 'Looking closer at face #3',
          'detail': 'Closest match is MAHESH BABU at 81%. The crop is small.',
          'thumb': _jpegBase64,
        }),
        ScanEvent.fromJson({
          'seq': 3,
          'ts': 8.5,
          'kind': 'think',
          'face_id': 2,
          'title': 'The picture is the problem, not the person',
          'tool': 'rescan_at_higher_resolution',
        }),
        ScanEvent.fromJson({
          'seq': 4,
          'ts': 22.9,
          'kind': 'tool',
          'face_id': 2,
          'title': 'Re-measured at 4.0x: 81% → 83%',
          'tool': 'rescan_at_higher_resolution',
          'outcome': 'uncertain',
        }),
        ScanEvent.fromJson({
          'seq': 5,
          'ts': 27.2,
          'kind': 'verdict',
          'face_id': 2,
          'title': 'Correction: face #3 is NTR, not MAHESH BABU',
          'detail': 'The vector search had the wrong student at the top.',
          'outcome': 'present',
          'corrected': true,
        }),
        ScanEvent.fromJson({
          'seq': 6,
          'ts': 9.1,
          'kind': 'observe',
          'face_id': 5,
          'title': 'Looking closer at face #6',
          'detail': 'No student scores high enough to be a match.',
        }),
        ScanEvent.fromJson({
          'seq': 7,
          'ts': 30.0,
          'kind': 'tool',
          'face_id': 5,
          'title': 'Second opinion failed',
          'detail': 'Gemini call failed: 504 Deadline Exceeded.',
          'tool': 'gemini_identify',
          'outcome': 'error',
        }),
        ScanEvent.fromJson({
          'seq': 8,
          'ts': 30.1,
          'kind': 'verdict',
          'face_id': 5,
          'title': 'Face #6 is not an enrolled student',
          'outcome': 'stranger',
        }),
        ScanEvent.fromJson({
          'seq': 9,
          'ts': 31.0,
          'kind': 'observe',
          'face_id': 6,
          'title': 'Looking closer at face #7',
          'detail': 'Still being examined.',
        }),
      ]);
      return progress;
    }

    testWidgets('renders every kind of step without a layout error',
        (tester) async {
      tester.view.physicalSize = const Size(1000, 4000);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      await tester.pumpWidget(
        MaterialApp(home: Scaffold(body: ReasoningTrace(progress: buildProgress()))),
      );
      // Not pumpAndSettle: the live spine and safelight animate forever by
      // design, so waiting for stillness would time out rather than pass.
      await tester.pump(const Duration(milliseconds: 400));

      // Nested IntrinsicHeight rows with flex children are where Flutter
      // throws "cannot compute intrinsic dimensions"; this is the assertion
      // that matters.
      expect(tester.takeException(), isNull);

      expect(find.text('Scanning the photo for faces'), findsOneWidget);
      expect(find.text('Correction: face #3 is NTR, not MAHESH BABU'), findsOneWidget);
      expect(find.text('CORRECTION'), findsOneWidget);
      expect(find.text('RE-CROP'), findsOneWidget);
      expect(find.text('SECOND OPINION'), findsOneWidget);
      // A face still being worked shows as live, not as a result.
      expect(find.text('EXAMINING'), findsOneWidget);
      expect(find.text('NOT ENROLLED'), findsOneWidget);
      // The thumbnail from the trace is actually drawn.
      expect(find.byType(Image), findsOneWidget);
    });

    testWidgets('an empty scan renders nothing rather than throwing',
        (tester) async {
      await tester.pumpWidget(
        MaterialApp(home: Scaffold(body: ReasoningTrace(progress: ScanProgress()))),
      );
      await tester.pump(const Duration(milliseconds: 200));
      expect(tester.takeException(), isNull);
    });
  });

  test('the sample thumbnail really is decodable', () {
    expect(base64Decode(_jpegBase64).length, greaterThan(100));
  });
}
