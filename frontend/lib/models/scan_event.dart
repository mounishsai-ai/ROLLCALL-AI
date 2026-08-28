import 'dart:convert';
import 'dart:typed_data';

/// One step of the backend's reasoning, as it happened.
class ScanEvent {
  final int seq;
  final double ts;

  /// status  - about the scan as a whole
  /// observe - what the system sees about one face
  /// think   - a decision about what to do next
  /// tool    - the result of running something
  /// verdict - the conclusion for one face
  final String kind;
  final String title;
  final String detail;
  final int? faceId;
  final String? tool;
  final String? outcome;
  final String? confidence;
  final bool corrected;
  final Uint8List? thumb;

  const ScanEvent({
    required this.seq,
    required this.ts,
    required this.kind,
    required this.title,
    required this.detail,
    this.faceId,
    this.tool,
    this.outcome,
    this.confidence,
    this.corrected = false,
    this.thumb,
  });

  factory ScanEvent.fromJson(Map<String, dynamic> json) {
    Uint8List? thumb;
    final raw = json['thumb'];
    if (raw is String && raw.isNotEmpty) {
      // A malformed thumbnail is not worth losing the reasoning over.
      try {
        thumb = base64Decode(raw);
      } catch (_) {
        thumb = null;
      }
    }
    return ScanEvent(
      seq: (json['seq'] as num?)?.toInt() ?? 0,
      ts: (json['ts'] as num?)?.toDouble() ?? 0,
      kind: json['kind'] as String? ?? 'status',
      title: json['title'] as String? ?? '',
      detail: json['detail'] as String? ?? '',
      faceId: (json['face_id'] as num?)?.toInt(),
      tool: json['tool'] as String?,
      outcome: json['outcome'] as String?,
      confidence: json['confidence'] as String?,
      corrected: json['corrected'] == true,
      thumb: thumb,
    );
  }
}

/// Everything known about one face under examination, assembled from the
/// events that mention it.
///
/// Events arrive interleaved because faces are investigated in parallel, so
/// the stream is regrouped by face: one card per face, growing as its own
/// investigation proceeds.
class FaceCase {
  final int faceId;
  Uint8List? thumb;
  final List<ScanEvent> steps = [];

  /// 'working' until a verdict lands, then 'present' / 'stranger' / 'unsure'.
  String state = 'working';

  FaceCase(this.faceId);

  void add(ScanEvent event) {
    thumb ??= event.thumb;
    steps.add(event);
    if (event.kind == 'verdict') {
      state = event.outcome ?? 'unsure';
    }
  }

  bool get isWorking => state == 'working';

  String get stateLabel => switch (state) {
        'present' => 'PRESENT',
        'stranger' => 'NOT ENROLLED',
        'unsure' => 'NEEDS A HUMAN',
        _ => 'EXAMINING',
      };
}

/// A running scan: the ordered stream plus the per-face grouping.
class ScanProgress {
  final List<ScanEvent> stream = [];
  final Map<int, FaceCase> cases = {};
  final List<ScanEvent> scanNotes = [];

  int cursor = 0;
  String status = 'running';
  String? error;
  Map<String, dynamic>? result;

  bool get isRunning => status == 'running';

  void ingest(List<ScanEvent> events) {
    for (final event in events) {
      stream.add(event);
      if (event.faceId == null) {
        scanNotes.add(event);
      } else {
        cases.putIfAbsent(event.faceId!, () => FaceCase(event.faceId!)).add(event);
      }
    }
  }

  int get settledCount => cases.values.where((c) => c.state == 'present').length;
  int get openCount => cases.values.where((c) => c.isWorking).length;
}
