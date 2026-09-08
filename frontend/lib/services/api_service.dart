import 'dart:convert';
import 'dart:io';
import 'package:image_picker/image_picker.dart';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

class ApiService {
  /// How long to wait on a plain database call.
  ///
  /// Generous on purpose. The backend scales to zero when idle, so the first
  /// request after a quiet spell also pays for the container starting up. The
  /// old 10-15s budget was shorter than that and turned a perfectly healthy
  /// cold start into "the roster would not load".
  static const Duration _readTimeout = Duration(seconds: 90);

  static const String _configuredBaseUrl = String.fromEnvironment('API_BASE_URL', defaultValue: '');
  static const String _configuredApiKey = String.fromEnvironment('API_KEY', defaultValue: '');
  static String? _dynamicBaseUrl;
  static String? _dynamicApiKey;

  static Future<void> init() async {
    final prefs = await SharedPreferences.getInstance();
    _dynamicBaseUrl = prefs.getString('api_base_url');
    _dynamicApiKey = prefs.getString('api_key');
  }

  static Future<void> setBaseUrl(String url) async {
    // Basic cleanup
    if (url.endsWith('/')) {
      url = url.substring(0, url.length - 1);
    }
    if (!url.startsWith('http')) {
      url = 'http://$url';
    }
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('api_base_url', url);
    _dynamicBaseUrl = url;
  }

  /// The shared secret the backend checks on every request.
  ///
  /// Baked in at build time with `--dart-define=API_KEY=...`, or typed into
  /// Settings on a device. The typed one wins, so a demo build can be pointed
  /// at a different server without rebuilding.
  static String get apiKey {
    if (_dynamicApiKey != null && _dynamicApiKey!.isNotEmpty) return _dynamicApiKey!;
    return _configuredApiKey;
  }

  static bool get hasApiKey => apiKey.isNotEmpty;

  static Future<void> setApiKey(String key) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('api_key', key.trim());
    _dynamicApiKey = key.trim();
  }

  /// Headers for every call. Empty when no key is configured, which is what
  /// a local backend without `API_KEY` set expects.
  static Map<String, String> get _authHeaders =>
      hasApiKey ? {'X-API-Key': apiKey} : const {};

  /// URL for a student's registration photo.
  ///
  /// The key travels in the query string here, not a header: this URL is
  /// handed to an ordinary image widget, and an `<img>` request cannot carry
  /// custom headers. The backend accepts either.
  static String faceImageUrl(String regNumber) {
    final base = '$baseUrl/faces/$regNumber.jpg';
    return hasApiKey ? '$base?key=${Uri.encodeQueryComponent(apiKey)}' : base;
  }

  static String get baseUrl {
    if (_dynamicBaseUrl != null && _dynamicBaseUrl!.isNotEmpty) {
      return _dynamicBaseUrl!;
    }
    if (_configuredBaseUrl.isNotEmpty) {
      return _configuredBaseUrl;
    }
    if (kIsWeb) {
      return 'http://127.0.0.1:8000';
    }
    if (Platform.isAndroid) {
      return 'http://10.0.2.2:8000';
    }
    return 'http://127.0.0.1:8000';
  }

  static Future<Map<String, dynamic>> takeAttendance(
    XFile imageFile, {
    http.Client? client,
  }) async {
    final request = http.MultipartRequest('POST', Uri.parse('$baseUrl/take_attendance'));
    request.headers.addAll(_authHeaders);
    final bytes = await imageFile.readAsBytes();
    request.files.add(http.MultipartFile.fromBytes('file', bytes, filename: imageFile.name.isEmpty ? 'upload.jpg' : imageFile.name));
    final multipartClient = client ?? http.Client();

    try {
      final response = await multipartClient.send(request).timeout(const Duration(seconds: 120));
      final body = await response.stream.bytesToString();
      return _parseJsonResponse(response.statusCode, body, 'attendance');
    } finally {
      if (client == null) {
        multipartClient.close();
      }
    }
  }

  /// Starts an adjudicated scan and returns its job id.
  ///
  /// This returns as soon as the photo is uploaded rather than waiting for the
  /// scan, so a slow investigation can no longer trip a request timeout. Follow
  /// it with [fetchScanProgress].
  static Future<String> startAgenticAttendance(
    XFile imageFile, {
    http.Client? client,
  }) async {
    final request = http.MultipartRequest('POST', Uri.parse('$baseUrl/take_attendance_agentic'));
    request.headers.addAll(_authHeaders);
    final bytes = await imageFile.readAsBytes();
    request.files.add(http.MultipartFile.fromBytes('file', bytes,
        filename: imageFile.name.isEmpty ? 'upload.jpg' : imageFile.name));
    final multipartClient = client ?? http.Client();

    try {
      final response = await multipartClient.send(request).timeout(const Duration(seconds: 60));
      final body = await response.stream.bytesToString();
      final parsed = _parseJsonResponse(response.statusCode, body, 'start scan');
      final jobId = parsed['job_id'];
      if (jobId is! String || jobId.isEmpty) {
        throw Exception('Server did not return a scan id.');
      }
      return jobId;
    } finally {
      if (client == null) {
        multipartClient.close();
      }
    }
  }

  /// Fetches everything that has happened on a scan since event [since].
  ///
  /// Pass back the `cursor` from the previous call so each reasoning step, and
  /// each face thumbnail, is downloaded exactly once.
  static Future<Map<String, dynamic>> fetchScanProgress(String jobId, {int since = 0}) async {
    final client = http.Client();
    try {
      final response = await client
          .get(Uri.parse('$baseUrl/attendance_job/$jobId?since=$since'), headers: _authHeaders)
          .timeout(const Duration(seconds: 20));
      return _parseJsonResponse(response.statusCode, response.body, 'scan progress');
    } finally {
      client.close();
    }
  }

  static Future<Map<String, dynamic>> registerStudent({
    required String name,
    required String regNumber,
    required XFile imageFile,
    http.Client? client,
  }) async {
    final request = http.MultipartRequest('POST', Uri.parse('$baseUrl/register_student'));
    request.headers.addAll(_authHeaders);
    request.fields['name'] = name;
    request.fields['reg_number'] = regNumber;
    final bytes = await imageFile.readAsBytes();
    request.files.add(http.MultipartFile.fromBytes('file', bytes, filename: imageFile.name.isEmpty ? 'upload.jpg' : imageFile.name));
    final multipartClient = client ?? http.Client();

    try {
      final response = await multipartClient.send(request).timeout(const Duration(seconds: 120));
      final body = await response.stream.bytesToString();
      return _parseJsonResponse(response.statusCode, body, 'registration');
    } finally {
      if (client == null) {
        multipartClient.close();
      }
    }
  }
  static Future<List<Map<String, dynamic>>> fetchStudents() async {
    final client = http.Client();
    try {
      final response = await client.get(
        Uri.parse('$baseUrl/students'),
        headers: _authHeaders,
      ).timeout(_readTimeout);
      final parsed = _parseJsonResponse(response.statusCode, response.body, 'fetch students');
      final students = parsed['students'] as List<dynamic>;
      return students.cast<Map<String, dynamic>>();
    } finally {
      client.close();
    }
  }

  static Future<void> deleteStudent(String regNumber) async {
    final client = http.Client();
    try {
      final response = await client.delete(
        Uri.parse('$baseUrl/students/$regNumber'),
        headers: _authHeaders,
      ).timeout(_readTimeout);
      _parseJsonResponse(response.statusCode, response.body, 'delete student');
    } finally {
      client.close();
    }
  }

  /// Fetch embedding processing statuses for all students (bulk polling).
  static Future<Map<String, dynamic>> fetchRegistrationStatuses() async {
    final client = http.Client();
    try {
      final response = await client.get(
        Uri.parse('$baseUrl/registration_statuses'),
        headers: _authHeaders,
      ).timeout(_readTimeout);
      final parsed = _parseJsonResponse(response.statusCode, response.body, 'registration statuses');
      return parsed;
    } finally {
      client.close();
    }
  }

  /// Check embedding processing status for a single student.
  static Future<Map<String, dynamic>> checkRegistrationStatus(String regNumber) async {
    final client = http.Client();
    try {
      final response = await client.get(
        Uri.parse('$baseUrl/registration_status/$regNumber'),
        headers: _authHeaders,
      ).timeout(_readTimeout);
      final parsed = _parseJsonResponse(response.statusCode, response.body, 'registration status');
      return (parsed['registration'] as Map<String, dynamic>?) ?? {};
    } finally {
      client.close();
    }
  }

  /// Records the register the teacher actually signed off.
  ///
  /// A scan proposes; a person decides. Until this existed, whatever the scan
  /// concluded simply became the record — fine for a demo, not fine for
  /// something a student's attendance depends on.
  static Future<Map<String, dynamic>> confirmAttendance(
    List<String> presentRegNumbers, {
    String? date,
  }) async {
    final client = http.Client();
    try {
      final response = await client
          .post(
            Uri.parse('$baseUrl/attendance/confirm'),
            headers: {..._authHeaders, 'Content-Type': 'application/json'},
            body: jsonEncode(<String, dynamic>{
              'present': presentRegNumbers,
              'date': ?date,
            }),
          )
          .timeout(_readTimeout);
      return _parseJsonResponse(response.statusCode, response.body, 'confirm attendance');
    } finally {
      client.close();
    }
  }

  /// Reads back a day's register and whether a human signed it off.
  static Future<Map<String, dynamic>> fetchAttendance({String? date}) async {
    final client = http.Client();
    try {
      final uri = Uri.parse('$baseUrl/attendance${date != null ? '?date=$date' : ''}');
      final response = await client.get(uri, headers: _authHeaders).timeout(_readTimeout);
      final parsed = _parseJsonResponse(response.statusCode, response.body, 'fetch attendance');
      return (parsed['attendance'] as Map<String, dynamic>?) ?? {};
    } finally {
      client.close();
    }
  }

  /// Turns whatever went wrong into something a teacher can act on.
  ///
  /// Lives here rather than in each screen so every screen says the same thing
  /// about the same failure. The cold start is the case worth naming: the
  /// backend sleeps when nobody is using it, and a raw "TimeoutException after
  /// 0:00:15" reads as broken when the honest answer is "still waking up".
  static String friendlyError(Object e) {
    final text = e.toString().replaceFirst('Exception: ', '');

    if (text.contains('TimeoutException') || text.contains('Future not completed')) {
      return 'The server did not answer in time. It sleeps when nobody is using '
          'it and can take a minute or two to wake up — try again.';
    }
    if (text.contains('SocketException') ||
        text.contains('Failed to fetch') ||
        text.contains('Connection')) {
      return 'Could not reach the server. Check the address in Settings, and '
          'that you are online.';
    }
    if (text.contains('access key')) return text;
    return text;
  }

  static Map<String, dynamic> parseJsonForTest(
    int statusCode,
    String body, {
    required String context,
  }) {
    return _parseJsonResponse(statusCode, body, context);
  }

  static Map<String, dynamic> _parseJsonResponse(int statusCode, String body, String context) {
    dynamic decodedBody;
    try {
      decodedBody = jsonDecode(body);
    } catch (_) {
      throw FormatException('Invalid JSON response during $context: $body');
    }

    if (decodedBody is! Map<String, dynamic>) {
      throw FormatException('Unexpected response format during $context.');
    }

    if (statusCode == 503) {
      final error = decodedBody['error'];
      final message = (error is Map<String, dynamic>) ? error['message'] : null;
      throw Exception(message ??
          'The server is starting up. Give it a minute and try again.');
    }

    if (statusCode == 401) {
      throw Exception(
          'Server rejected the access key. Open Settings and check the key matches the backend.');
    }

    if (statusCode < 200 || statusCode >= 300) {
      final error = decodedBody['error'];
      if (error is Map<String, dynamic>) {
        final message = error['message'] ?? 'Unknown server error';
        throw Exception('$context failed ($statusCode): $message');
      }
      throw Exception('$context failed ($statusCode): $decodedBody');
    }

    return decodedBody;
  }
}
