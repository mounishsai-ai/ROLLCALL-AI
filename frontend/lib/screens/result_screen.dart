import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../services/api_service.dart';
import '../theme/examination.dart';

/// Below this similarity, a match counts as "worked, but only just" and the
/// student is asked for a fresh photo.
///
/// This number is a judgement call, not a measurement. It has never been
/// calibrated against a real class, and the honest way to set it is to scan one
/// and look at where the scores actually fall. Too high and every student gets
/// nagged every week until they ignore it; too low and it never fires and the
/// feature does nothing.
///
/// It lives here, alone and named, so tuning it is one edit rather than a hunt
/// through widget code.
const double kPhotoDriftThreshold = 0.55;

/// The register: who the system says was here, and the teacher's decision on it.
///
/// The scan produces a proposal. This screen is where a person agrees or
/// disagrees with it, face by face, and signs it off. Nothing is a record until
/// they do.
///
/// Every row leads with the evidence rather than the name, because that is the
/// only claim being made: *this photo on file* and *this face in the room* are
/// the same person. A teacher cannot audit a similarity score, but they can
/// look at two faces. So the faces are the object and the name is the caption —
/// the opposite of every roll-call list, and the right way round for a screen
/// whose whole job is "do you agree?".
class ResultScreen extends StatefulWidget {
  final Map<String, dynamic> result;
  const ResultScreen({super.key, required this.result});

  @override
  State<ResultScreen> createState() => _ResultScreenState();
}

class _ResultScreenState extends State<ResultScreen> {
  /// Reg numbers the teacher currently considers present.
  late final Set<String> _ticked;
  bool _saving = false;
  String? _savedMessage;
  String? _error;

  List<Map<String, dynamic>> _people(String key) =>
      (widget.result[key] as List?)?.whereType<Map<String, dynamic>>().toList() ?? const [];

  /// Reg numbers read as numbers where they look like numbers, so 2 sorts
  /// before 10 rather than after it.
  static int _byRegNumber(Map<String, dynamic> a, Map<String, dynamic> b) {
    final ra = '${a['reg_number'] ?? ''}';
    final rb = '${b['reg_number'] ?? ''}';
    final na = int.tryParse(ra);
    final nb = int.tryParse(rb);
    if (na != null && nb != null) return na.compareTo(nb);
    return ra.compareTo(rb);
  }

  List<Map<String, dynamic>> _sorted(Iterable<Map<String, dynamic>> people) =>
      people.toList()..sort(_byRegNumber);

  @override
  void initState() {
    super.initState();
    // Start from what the system concluded. The teacher edits from there —
    // agreeing should cost no taps, disagreeing exactly one.
    _ticked = _people('present').map((p) => '${p['reg_number']}').toSet();
  }

  /// Everyone the maths settled on its own.
  List<Map<String, dynamic>> get _instant => _sorted(
      _people('present').where((p) => p['resolved_by'] == 'vector_match'));

  /// Everyone who needed the Adjudicator to reach an answer.
  List<Map<String, dynamic>> get _rescued => _sorted(
      _people('present').where((p) => p['resolved_by'] != 'vector_match'));

  Future<void> _confirm() async {
    setState(() {
      _saving = true;
      _error = null;
      _savedMessage = null;
    });
    try {
      await ApiService.confirmAttendance(_ticked.toList());
      if (!mounted) return;
      setState(() => _savedMessage = 'Register signed off — ${_ticked.length} present.');
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = ApiService.friendlyError(e));
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final unsure = _sorted(_people('unsure'));
    final absent = _sorted(_people('absent'));
    final strangers = _people('unknown_faces');

    return Scaffold(
      backgroundColor: Ex.ink,
      extendBodyBehindAppBar: true,
      appBar: Ex.bar('The register'),
      body: Ex.backdrop(
        child: Column(
          children: [
            Expanded(
              child: ListView(
                padding: const EdgeInsets.fromLTRB(18, 100, 18, 24),
                children: [
                  _Tally(
                    present: _ticked.length,
                    needsLook: unsure.length,
                    absent: absent.length,
                    strangers: strangers.length,
                  ),
                  _Group(
                    title: 'Matched instantly',
                    note: 'The measurements were decisive. No second opinion needed.',
                    accent: Ex.settled,
                    people: _instant,
                    ticked: _ticked,
                    onToggle: _toggle,
                  ),
                  _Group(
                    title: 'The system worked these out',
                    note: 'Not clear-cut at first. Each one says how it was settled.',
                    accent: Ex.safelight,
                    people: _rescued,
                    ticked: _ticked,
                    onToggle: _toggle,
                  ),
                  _Group(
                    title: 'Left for you',
                    note: 'Nothing convincing either way. Your call.',
                    accent: Ex.open,
                    people: unsure,
                    ticked: _ticked,
                    onToggle: _toggle,
                  ),
                  if (strangers.isNotEmpty) _Strangers(faces: strangers),
                  _Group(
                    title: 'Not found in the photo',
                    note: 'Tick anyone who was in the room but the camera missed.',
                    accent: Ex.outside,
                    people: absent,
                    ticked: _ticked,
                    onToggle: _toggle,
                  ),
                ],
              ),
            ),
            _ConfirmBar(
              count: _ticked.length,
              saving: _saving,
              savedMessage: _savedMessage,
              error: _error,
              onConfirm: _confirm,
            ),
          ],
        ),
      ),
    );
  }

  void _toggle(String reg) {
    setState(() {
      if (!_ticked.remove(reg)) _ticked.add(reg);
      // Any edit invalidates the previous sign-off message.
      _savedMessage = null;
    });
  }
}

// ──────────────────────────────────────────────
//  The signature: two faces, one seam
// ──────────────────────────────────────────────

/// The claim the whole product makes, drawn as one object.
///
/// Squares, butted together with a single hairline, deliberately *not* the
/// app's recurring disc. A disc is an avatar and says "this is a person"; this
/// is evidence and says "these two are being compared". Same size, same
/// treatment, so neither photo looks like the authority — the teacher decides
/// which one is wrong.
class _EvidencePlate extends StatelessWidget {
  final String regNumber;
  final Uint8List? found;
  final Color accent;
  const _EvidencePlate({required this.regNumber, required this.found, required this.accent});

  static const double _h = 62;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(8),
          child: Container(
            decoration: BoxDecoration(border: Border.all(color: Ex.rule)),
            child: Row(
              children: [
                _pane(child: _onFile()),
                Container(width: 1, height: _h, color: Ex.rule),
                _pane(child: _inTheRoom()),
              ],
            ),
          ),
        ),
        const SizedBox(height: 5),
        SizedBox(
          width: _h * 2 + 1,
          child: Row(
            children: [
              Expanded(child: Text('ON FILE', style: _cap, textAlign: TextAlign.center)),
              Expanded(child: Text('IN THE ROOM', style: _cap, textAlign: TextAlign.center)),
            ],
          ),
        ),
      ],
    );
  }

  static final _cap = Ex.data.copyWith(fontSize: 7.5, letterSpacing: 1.1, color: Ex.faint);

  Widget _pane({required Widget child}) =>
      SizedBox(width: _h, height: _h, child: child);

  Widget _onFile() => Image.network(
        ApiService.faceImageUrl(regNumber),
        fit: BoxFit.cover,
        errorBuilder: (_, _, _) => _blank(Icons.person_outline_rounded, 'no photo'),
      );

  Widget _inTheRoom() => found == null
      // A confidently matched face still has a crop; a missing one means the
      // student was never seen, which is worth saying rather than hiding.
      ? _blank(Icons.search_off_rounded, 'not seen')
      : Image.memory(found!, fit: BoxFit.cover, gaplessPlayback: true);

  Widget _blank(IconData icon, String label) => Container(
        color: Colors.white.withValues(alpha: 0.04),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, size: 15, color: Ex.faint),
            const SizedBox(height: 3),
            Text(label, style: Ex.data.copyWith(fontSize: 7, color: Ex.faint)),
          ],
        ),
      );
}

// ──────────────────────────────────────────────
//  Rows and groups
// ──────────────────────────────────────────────

class _StudentRow extends StatelessWidget {
  final Map<String, dynamic> person;
  final Color accent;
  final bool ticked;
  final VoidCallback onToggle;

  const _StudentRow({
    required this.person,
    required this.accent,
    required this.ticked,
    required this.onToggle,
  });

  Uint8List? get _found {
    final raw = person['thumb'];
    if (raw is! String || raw.isEmpty) return null;
    try {
      return base64Decode(raw);
    } catch (_) {
      return null;
    }
  }

  /// Should this student be asked for a fresh photo?
  ///
  /// People change — a beard, glasses, a different haircut — and the photo on
  /// file quietly stops looking like them. The system keeps coping, scoring
  /// lower every term, until one day it stops recognising them and nobody
  /// knows why. A weak-but-passing match, or one the system had to work for,
  /// is that drift showing up early enough to fix.
  String? get _driftReason {
    final score = (person['score'] as num?)?.toDouble();
    final how = person['resolved_by'];
    if (how == 'gemini_identify') {
      return 'The measurements could not place them; it took a closer look to be sure.';
    }
    if (how == 'rescan') {
      return 'Only matched after re-examining the photo more closely.';
    }
    if (score != null && score < kPhotoDriftThreshold) {
      return 'Matched, but only just — ${(score * 100).round()}%.';
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final reg = '${person['reg_number'] ?? ''}';
    final name = '${person['name'] ?? 'Unknown'}';
    final reason = person['reason'];
    final corrected = person['corrected'] == true;
    final drift = _driftReason;

    return InkWell(
      onTap: onToggle,
      borderRadius: BorderRadius.circular(14),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 10),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _EvidencePlate(regNumber: reg, found: _found, accent: accent),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Text(reg.padLeft(2, '0'),
                          style: Ex.data.copyWith(fontSize: 11, color: accent)),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(name,
                            style: Ex.verdict.copyWith(fontSize: 15),
                            overflow: TextOverflow.ellipsis),
                      ),
                    ],
                  ),
                  if (corrected) ...[
                    const SizedBox(height: 4),
                    Text('CORRECTED THE FIRST GUESS',
                        style: Ex.data.copyWith(fontSize: 8.5, color: Ex.safelight)),
                  ],
                  if (reason is String && reason.isNotEmpty) ...[
                    const SizedBox(height: 4),
                    Text(reason, style: Ex.reasonQuiet.copyWith(fontSize: 12.5)),
                  ],
                  if (drift != null) ...[
                    const SizedBox(height: 7),
                    _DriftNotice(reason: drift),
                  ],
                ],
              ),
            ),
            const SizedBox(width: 10),
            _Tick(on: ticked, accent: accent, onTap: onToggle),
          ],
        ),
      ),
    );
  }
}

/// The differentiator, stated as something a teacher can act on today.
class _DriftNotice extends StatelessWidget {
  final String reason;
  const _DriftNotice({required this.reason});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(9, 7, 9, 8),
      decoration: BoxDecoration(
        color: Ex.safelight.withValues(alpha: 0.09),
        borderRadius: BorderRadius.circular(9),
        border: Border.all(color: Ex.safelight.withValues(alpha: 0.30)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(Icons.autorenew_rounded, size: 13, color: Ex.safelight),
          const SizedBox(width: 7),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('TIME FOR A NEW PHOTO',
                    style: Ex.data.copyWith(fontSize: 8.5, color: Ex.safelight)),
                const SizedBox(height: 3),
                Text(reason, style: Ex.reasonQuiet.copyWith(fontSize: 11.5, height: 1.35)),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _Tick extends StatelessWidget {
  final bool on;
  final Color accent;
  final VoidCallback onTap;
  const _Tick({required this.on, required this.accent, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return Semantics(
      checked: on,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(8),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 140),
          width: 30,
          height: 30,
          decoration: BoxDecoration(
            color: on ? accent.withValues(alpha: 0.22) : Colors.transparent,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: on ? accent : Ex.rule, width: 1.4),
          ),
          child: on
              ? Icon(Icons.check_rounded, size: 18, color: accent)
              : const SizedBox.shrink(),
        ),
      ),
    );
  }
}

class _Group extends StatelessWidget {
  final String title;
  final String note;
  final Color accent;
  final List<Map<String, dynamic>> people;
  final Set<String> ticked;
  final void Function(String reg) onToggle;

  const _Group({
    required this.title,
    required this.note,
    required this.accent,
    required this.people,
    required this.ticked,
    required this.onToggle,
  });

  @override
  Widget build(BuildContext context) {
    if (people.isEmpty) return const SizedBox.shrink();

    return Padding(
      padding: const EdgeInsets.only(top: 26),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(width: 3, height: 15, color: accent),
              const SizedBox(width: 9),
              Expanded(
                child: Text(title.toUpperCase(),
                    style: Ex.dataStrong.copyWith(fontSize: 10.5, letterSpacing: 1.5)),
              ),
              Text('${people.length}', style: Ex.data.copyWith(fontSize: 12, color: accent)),
            ],
          ),
          const SizedBox(height: 5),
          Padding(
            padding: const EdgeInsets.only(left: 12),
            child: Text(note, style: Ex.reasonQuiet.copyWith(fontSize: 12)),
          ),
          const SizedBox(height: 6),
          ...people.map((p) => _StudentRow(
                person: p,
                accent: accent,
                ticked: ticked.contains('${p['reg_number']}'),
                onToggle: () => onToggle('${p['reg_number']}'),
              )),
        ],
      ),
    );
  }
}

class _Strangers extends StatelessWidget {
  final List<Map<String, dynamic>> faces;
  const _Strangers({required this.faces});

  Uint8List? _thumb(Map<String, dynamic> f) {
    final raw = f['thumb'];
    if (raw is! String || raw.isEmpty) return null;
    try {
      return base64Decode(raw);
    } catch (_) {
      return null;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 26),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(width: 3, height: 15, color: Ex.outside),
              const SizedBox(width: 9),
              Expanded(
                child: Text('NOT ON THE ROSTER',
                    style: Ex.dataStrong.copyWith(fontSize: 10.5, letterSpacing: 1.5)),
              ),
              Text('${faces.length}', style: Ex.data.copyWith(fontSize: 12, color: Ex.outside)),
            ],
          ),
          const SizedBox(height: 5),
          Padding(
            padding: const EdgeInsets.only(left: 12),
            child: Text(
              'Somebody was in the room who is not enrolled. Nobody is marked present for them.',
              style: Ex.reasonQuiet.copyWith(fontSize: 12),
            ),
          ),
          const SizedBox(height: 10),
          ...faces.map((f) {
            final thumb = _thumb(f);
            return Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  ClipRRect(
                    borderRadius: BorderRadius.circular(8),
                    child: Container(
                      width: 62,
                      height: 62,
                      decoration: BoxDecoration(border: Border.all(color: Ex.rule)),
                      child: thumb != null
                          ? Image.memory(thumb, fit: BoxFit.cover)
                          : Container(
                              color: Colors.white.withValues(alpha: 0.04),
                              child: const Icon(Icons.person_off_outlined,
                                  size: 18, color: Ex.faint),
                            ),
                    ),
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Text('${f['reason'] ?? 'Not any of the enrolled students.'}',
                        style: Ex.reasonQuiet.copyWith(fontSize: 12.5)),
                  ),
                ],
              ),
            );
          }),
        ],
      ),
    );
  }
}

// ──────────────────────────────────────────────
//  Tally and the one action
// ──────────────────────────────────────────────

class _Tally extends StatelessWidget {
  final int present;
  final int needsLook;
  final int absent;
  final int strangers;

  const _Tally({
    required this.present,
    required this.needsLook,
    required this.absent,
    required this.strangers,
  });

  @override
  Widget build(BuildContext context) {
    return Ex.glass(
      padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 8),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
        children: [
          _cell('$present', 'PRESENT', Ex.settled),
          _cell('$needsLook', 'YOUR CALL', Ex.open),
          _cell('$absent', 'ABSENT', Ex.outside),
          if (strangers > 0) _cell('$strangers', 'VISITORS', Ex.safelight),
        ],
      ),
    );
  }

  Widget _cell(String value, String label, Color color) => Column(
        children: [
          Text(value, style: Ex.tally.copyWith(color: color, fontSize: 28)),
          const SizedBox(height: 3),
          Text(label, style: Ex.data.copyWith(fontSize: 8.5, letterSpacing: 1.2)),
        ],
      );
}

/// One action, named for what it produces.
class _ConfirmBar extends StatelessWidget {
  final int count;
  final bool saving;
  final String? savedMessage;
  final String? error;
  final VoidCallback onConfirm;

  const _ConfirmBar({
    required this.count,
    required this.saving,
    required this.savedMessage,
    required this.error,
    required this.onConfirm,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(18, 12, 18, 20),
      decoration: BoxDecoration(
        color: Ex.ink.withValues(alpha: 0.92),
        border: Border(top: BorderSide(color: Ex.rule)),
      ),
      child: SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (savedMessage != null) ...[
              Text(savedMessage!,
                  style: Ex.reason.copyWith(fontSize: 13, color: Ex.settled)),
              const SizedBox(height: 10),
            ],
            if (error != null) ...[
              Text(error!, style: Ex.reason.copyWith(fontSize: 13, color: Ex.outside)),
              const SizedBox(height: 10),
            ],
            SizedBox(
              width: double.infinity,
              child: FilledButton(
                style: Ex.primaryButton,
                onPressed: saving ? null : onConfirm,
                child: saving
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2, color: Color(0xFF3A2408)),
                      )
                    : Text('CONFIRM REGISTER  ·  $count PRESENT',
                        style: Ex.dataStrong.copyWith(
                            color: const Color(0xFF3A2408), letterSpacing: 1.2)),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
