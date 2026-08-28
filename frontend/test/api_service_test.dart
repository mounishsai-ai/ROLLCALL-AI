import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/services/api_service.dart';

void main() {
  group('ApiService JSON parsing', () {
    test('parses valid success payload', () {
      final result = ApiService.parseJsonForTest(
        200,
        '{"status":"success","present":[],"absent":[],"unsure":[]}',
        context: 'attendance',
      );

      expect(result['status'], 'success');
    });

    test('throws on invalid JSON', () {
      expect(
        () => ApiService.parseJsonForTest(200, 'not-json', context: 'attendance'),
        throwsA(isA<FormatException>()),
      );
    });

    test('throws server message on non-2xx response', () {
      expect(
        () => ApiService.parseJsonForTest(
          400,
          '{"status":"error","error":{"code":"HTTP_ERROR","message":"Bad request"}}',
          context: 'registration',
        ),
        throwsA(isA<Exception>()),
      );
    });
  });
}
