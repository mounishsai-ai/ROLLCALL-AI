import 'dart:async';
import 'package:flutter/material.dart';
import '../services/api_service.dart';
import '../theme/examination.dart';
import 'register_screen.dart';

/// The roster: who the system is able to recognise.
class ManageStudentsScreen extends StatefulWidget {
  const ManageStudentsScreen({super.key});

  @override
  State<ManageStudentsScreen> createState() => _ManageStudentsScreenState();
}

class _ManageStudentsScreenState extends State<ManageStudentsScreen> {
  List<Map<String, dynamic>> _students = [];
  bool _isLoading = true;
  String? _error;

  /// Tracks embedding processing status per reg_number
  Map<String, String> _embeddingStatuses = {};
  Set<String> _arcfaceRegistered = {};
  Set<String> _adafaceRegistered = {};
  Timer? _statusPollTimer;

  @override
  void initState() {
    super.initState();
    _loadStudents();
  }

  @override
  void dispose() {
    _statusPollTimer?.cancel();
    super.dispose();
  }

  Future<void> _loadStudents() async {
    setState(() {
      _isLoading = true;
      _error = null;
    });
    try {
      final students = await ApiService.fetchStudents();
      if (!mounted) return;
      setState(() {
        _students = students;
        _isLoading = false;
      });
      _pollRegistrationStatuses();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = ApiService.friendlyError(e);
        _isLoading = false;
      });
    }
  }

  /// Polls the backend for embedding processing statuses, stopping once every
  /// student is done.
  Future<void> _pollRegistrationStatuses() async {
    _statusPollTimer?.cancel();
    await _fetchStatuses();

    if (_hasProcessingStudents()) {
      _statusPollTimer = Timer.periodic(const Duration(seconds: 3), (_) async {
        await _fetchStatuses();
        if (!_hasProcessingStudents()) {
          _statusPollTimer?.cancel();
          _statusPollTimer = null;
        }
      });
    }
  }

  bool _hasProcessingStudents() =>
      _embeddingStatuses.values.any((s) => s == 'processing');

  Future<void> _fetchStatuses() async {
    try {
      final statuses = await ApiService.fetchRegistrationStatuses();
      if (!mounted) return;
      setState(() {
        _embeddingStatuses = {};
        final activeQueue = statuses['active_queue'] as Map<String, dynamic>? ?? {};
        activeQueue.forEach((regNumber, value) {
          if (value is Map<String, dynamic>) {
            _embeddingStatuses[regNumber] = (value['status'] as String?) ?? 'unknown';
          }
        });

        _arcfaceRegistered = ((statuses['arcface_registered'] as List<dynamic>?) ?? [])
            .map((e) => e.toString())
            .toSet();
        _adafaceRegistered = ((statuses['adaface_registered'] as List<dynamic>?) ?? [])
            .map((e) => e.toString())
            .toSet();
      });
    } catch (_) {
      // Best-effort: the roster is still usable without live status.
    }
  }

  Future<void> _deleteStudent(String regNumber, String name) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF10314A),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(20),
          side: BorderSide(color: Ex.rule),
        ),
        title: Text('REMOVE $name'.toUpperCase(),
            style: Ex.dataStrong.copyWith(letterSpacing: 1.6)),
        content: Text(
          'This deletes their face data permanently. They will not be recognised in any '
          'future scan until they are added again.',
          style: Ex.reasonQuiet.copyWith(fontSize: 14),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text('KEEP', style: Ex.data.copyWith(fontSize: 11)),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text('REMOVE',
                style: Ex.data.copyWith(fontSize: 11, color: Ex.outside)),
          ),
        ],
      ),
    );

    if (confirmed != true) return;

    try {
      await ApiService.deleteStudent(regNumber);
      if (!mounted) return;
      Ex.say(context, '$name removed from the roster.');
      _loadStudents();
    } catch (e) {
      if (!mounted) return;
      Ex.say(context, 'Could not remove them. ${e.toString().replaceFirst('Exception: ', '')}',
          bad: true);
    }
  }

  Future<void> _addStudent() async {
    await Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => const RegisterScreen()),
    );
    _loadStudents();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Ex.ink,
      extendBodyBehindAppBar: true,
      appBar: Ex.bar('The roster', actions: [
        IconButton(
          icon: const Icon(Icons.refresh_rounded, size: 20),
          color: Ex.mute,
          onPressed: _loadStudents,
          tooltip: 'Reload',
        ),
      ]),
      body: Ex.backdrop(child: _buildBody()),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _addStudent,
        backgroundColor: Ex.safelight,
        foregroundColor: const Color(0xFF3A2408),
        elevation: 0,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
        icon: const Icon(Icons.add_rounded, size: 20),
        label: Text('ADD STUDENT',
            style: Ex.dataStrong
                .copyWith(color: const Color(0xFF3A2408), letterSpacing: 1.4)),
      ),
    );
  }

  Widget _buildBody() {
    if (_isLoading) {
      return Center(child: Text('Loading the roster', style: Ex.reasonQuiet));
    }

    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('THE ROSTER WOULD NOT LOAD',
                  style: Ex.data.copyWith(color: Ex.outside, letterSpacing: 1.6)),
              const SizedBox(height: 12),
              Text(_error!, style: Ex.reason),
              const SizedBox(height: 12),
              Text(
                'Check that the backend is running and that the address in Settings is right.',
                style: Ex.reasonQuiet.copyWith(fontSize: 13),
              ),
              const SizedBox(height: 22),
              FilledButton(
                style: Ex.primaryButton,
                onPressed: _loadStudents,
                child: Text('TRY AGAIN',
                    style: Ex.dataStrong.copyWith(color: Ex.ink, letterSpacing: 1.6)),
              ),
            ],
          ),
        ),
      );
    }

    if (_students.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(40),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text('Nobody on the roster yet',
                  style: Ex.verdict.copyWith(fontSize: 18), textAlign: TextAlign.center),
              const SizedBox(height: 10),
              Text(
                'Add a student and the system will learn their face. '
                'Until then, a scan has nobody to match against.',
                style: Ex.reasonQuiet,
                textAlign: TextAlign.center,
              ),
            ],
          ),
        ),
      );
    }

    return RefreshIndicator(
      onRefresh: _loadStudents,
      color: Ex.safelight,
      backgroundColor: Ex.bench,
      child: ListView.builder(
        padding: const EdgeInsets.fromLTRB(18, 104, 18, 110),
        itemCount: _students.length + 1,
        itemBuilder: (context, index) {
          if (index == 0) {
            return Padding(
              padding: const EdgeInsets.only(bottom: 16),
              child: Text(
                '${_students.length} STUDENT${_students.length == 1 ? '' : 'S'}',
                style: Ex.data.copyWith(fontSize: 10, letterSpacing: 2),
              ),
            );
          }

          final student = _students[index - 1];
          final name = student['name'] ?? 'Unknown';
          final regNumber = student['reg_number'] ?? '';
          return _StudentRow(
            name: name,
            regNumber: regNumber,
            processing: _embeddingStatuses[regNumber] == 'processing',
            inArcface: _arcfaceRegistered.contains(regNumber),
            inAdaface: _adafaceRegistered.contains(regNumber),
            onDelete: () => _deleteStudent(regNumber, name),
          );
        },
      ),
    );
  }
}

class _StudentRow extends StatelessWidget {
  final String name;
  final String regNumber;
  final bool processing;
  final bool inArcface;
  final bool inAdaface;
  final VoidCallback onDelete;

  const _StudentRow({
    required this.name,
    required this.regNumber,
    required this.processing,
    required this.inArcface,
    required this.inAdaface,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    // A student missing from an index cannot be recognised while that backend
    // is active — they would silently read absent in every scan. Worth showing.
    final incomplete = !inArcface || !inAdaface;

    final accent = processing
        ? Ex.safelight
        : incomplete
            ? Ex.open
            : Ex.settled;

    return Padding(
      padding: const EdgeInsets.only(bottom: 9),
      child: Ex.glass(
        radius: 18,
        edge: accent.withValues(alpha: 0.24),
        padding: const EdgeInsets.fromLTRB(14, 12, 6, 12),
        child: Row(
          children: [
            Ex.disc(
              size: 48,
              glow: accent,
              glowStrength: 0.35,
              filled: false,
              child: Image.network(
                ApiService.faceImageUrl(regNumber),
                fit: BoxFit.cover,
                errorBuilder: (_, _, _) => Center(
                  child: Text(
                    name.isNotEmpty ? name[0].toUpperCase() : '?',
                    style: Ex.dataStrong.copyWith(fontSize: 16, color: Ex.mute),
                  ),
                ),
              ),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(name, style: Ex.verdict.copyWith(fontSize: 15.5)),
                      ),
                      Text(regNumber,
                          style: Ex.data
                              .copyWith(fontSize: 11, fontWeight: FontWeight.w400)),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      _Tag(label: 'ARCFACE', on: inArcface, busy: processing && !inArcface),
                      const SizedBox(width: 10),
                      _Tag(label: 'ADAFACE', on: inAdaface, busy: processing && !inAdaface),
                    ],
                  ),
                ],
              ),
            ),
            IconButton(
              icon: const Icon(Icons.close_rounded, size: 18),
              color: Ex.faint,
              onPressed: onDelete,
              tooltip: 'Remove $name',
            ),
          ],
        ),
      ),
    );
  }
}

/// Which face index holds this student. Only one backend is active at a time,
/// so a missing tag is the difference between recognised and silently absent.
class _Tag extends StatelessWidget {
  final String label;
  final bool on;
  final bool busy;

  const _Tag({required this.label, required this.on, required this.busy});

  @override
  Widget build(BuildContext context) {
    final color = busy ? Ex.safelight : (on ? Ex.settled : Ex.faint);
    return Tooltip(
      message: busy
          ? 'Still processing for $label'
          : on
              ? 'Ready in the $label index'
              : 'Not in the $label index — will not be recognised while it is active',
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 6,
            height: 6,
            decoration: BoxDecoration(color: color, shape: BoxShape.circle),
          ),
          const SizedBox(width: 6),
          Text(label, style: Ex.data.copyWith(fontSize: 9, color: color)),
        ],
      ),
    );
  }
}
