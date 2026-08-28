import 'dart:convert';
import 'dart:io';
import 'package:image_picker/image_picker.dart';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

class ApiService {
  static const String _configuredBaseUrl = String.fromEnvironment('API_BASE_URL', defaultValue: '');
  static String? _dynamicBaseUrl;

  static Future<void> init() async {
    final prefs = await SharedPreferences.getInstance();
    _dynamicBaseUrl = prefs.getString('api_base_url');
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
          .get(Uri.parse('$baseUrl/attendance_job/$jobId?since=$since'))
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
      ).timeout(const Duration(seconds: 15));
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
      ).timeout(const Duration(seconds: 15));
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
      ).timeout(const Duration(seconds: 10));
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
      ).timeout(const Duration(seconds: 10));
      final parsed = _parseJsonResponse(response.statusCode, response.body, 'registration status');
      return (parsed['registration'] as Map<String, dynamic>?) ?? {};
    } finally {
      client.close();
    }
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
