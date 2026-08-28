import 'package:flutter/material.dart';

import '../theme/examination.dart';

/// The register: who was marked present, who was not, and why.
///
/// Every entry carries the reason it was decided that way. A teacher signing
/// off on attendance is accountable for it, so a name with no justification
/// behind it is not good enough — especially for the ones a model rescued.
class ResultScreen extends StatelessWidget {
  final Map<String, dynamic> result;
  const ResultScreen({super.key, required this.result});

  List<Map<String, dynamic>> _people(String key) =>
      (result[key] as List?)?.whereType<Map<String, dynamic>>().toList() ?? const [];

  @override
  Widget build(BuildContext context) {
    final present = _people('present');
    final unsure = _people('unsure');
    final absent = _people('absent');
    final strangers = _people('unknown_faces');

    return Scaffold(
      backgroundColor: Ex.ink,
      extendBodyBehindAppBar: true,
      appBar: Ex.bar('The register'),
      body: Ex.backdrop(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(18, 100, 18, 40),
          children: [
            _Tally(present: present.length, unsure: unsure.length, absent: absent.length),
            _Section(
              title: 'Present',
              note: 'Counted as here.',
              color: Ex.settled,
              people: present,
            ),
            if (unsure.isNotEmpty)
              _Section(
                title: 'Left for you',
                note: 'The system could not settle these. Decide them yourself.',
                color: Ex.open,
                people: unsure,
              ),
            if (strangers.isNotEmpty) _Strangers(faces: strangers),
            _Section(
              title: 'Absent',
              note: 'No face in the photo belonged to them.',
              color: Ex.outside,
              people: absent,
            ),
          ],
        ),
      ),
    );
  }
}

class _Tally extends StatelessWidget {
  final int present;
  final int unsure;
  final int absent;

  const _Tally({required this.present, required this.unsure, required this.absent});

  @override
  Widget build(BuildContext context) {
    return Ex.glass(
      radius: 20,
      blurred: true,
      padding: const EdgeInsets.symmetric(vertical: 20),
      child: Row(
        children: [
          _cell('PRESENT', present, Ex.settled),
          Container(width: 1, height: 34, color: Ex.rule),
          _cell('OPEN', unsure, Ex.open),
          Container(width: 1, height: 34, color: Ex.rule),
          _cell('ABSENT', absent, Ex.outside),
        ],
      ),
    );
  }

  Widget _cell(String label, int value, Color color) => Expanded(
        child: Column(
          children: [
            Text('$value', style: Ex.tally.copyWith(color: color, fontSize: 30)),
            const SizedBox(height: 4),
            Text(label, style: Ex.data.copyWith(fontSize: 9, letterSpacing: 1.5)),
          ],
        ),
      );
}

class _Section extends StatelessWidget {
  final String title;
  final String note;
  final Color color;
  final List<Map<String, dynamic>> people;

  const _Section({
    required this.title,
    required this.note,
    required this.color,
    required this.people,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SizedBox(height: 30),
        Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Container(
              width: 9,
              height: 9,
              decoration: BoxDecoration(
                color: color,
                shape: BoxShape.circle,
                boxShadow: [
                  BoxShadow(color: color.withValues(alpha: 0.6), blurRadius: 8),
                ],
              ),
            ),
            const SizedBox(width: 11),
            Text(title, style: Ex.display.copyWith(fontSize: 21)),
            const SizedBox(width: 10),
            Text('${people.length}', style: Ex.data.copyWith(fontSize: 12)),
          ],
        ),
        const SizedBox(height: 4),
        Padding(
          padding: const EdgeInsets.only(left: 18),
          child: Text(note, style: Ex.reasonQuiet.copyWith(fontSize: 13)),
        ),
        const SizedBox(height: 14),
        if (people.isEmpty)
          Padding(
            padding: const EdgeInsets.only(left: 18, bottom: 4),
            child: Text('Nobody.', style: Ex.reasonQuiet),
          )
        else
          for (final person in people) _PersonRow(person: person, color: color),
      ],
    );
  }
}

class _PersonRow extends StatelessWidget {
  final Map<String, dynamic> person;
  final Color color;

  const _PersonRow({required this.person, required this.color});

  String? get _how => switch (person['resolved_by']) {
        'vector_match' => 'MATCHED DIRECTLY',
        'rescan' => 'RESOLVED BY RE-CROP',
        'gemini_identify' => 'SECOND OPINION',
        'unresolved' => 'UNRESOLVED',
        _ => null,
      };

  @override
  Widget build(BuildContext context) {
    final reason = person['reason'] as String?;
    final corrected = person['corrected'] == true;
    final how = _how;

    return Padding(
      padding: const EdgeInsets.only(bottom: 9),
      child: Ex.glass(
        radius: 16,
        edge: color.withValues(alpha: 0.28),
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 15),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  width: 7,
                  height: 7,
                  decoration: BoxDecoration(color: color, shape: BoxShape.circle),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    '${person['name'] ?? 'Unknown'}',
                    style: Ex.verdict.copyWith(fontSize: 16),
                  ),
                ),
                Text('${person['reg_number'] ?? ''}',
                    style: Ex.data.copyWith(fontSize: 12, fontWeight: FontWeight.w400)),
              ],
            ),
            if (how != null || corrected) ...[
              const SizedBox(height: 9),
              Row(
                children: [
                  if (how != null)
                    Text(how, style: Ex.data.copyWith(fontSize: 9, color: Ex.faint)),
                  if (corrected) ...[
                    const SizedBox(width: 8),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                      decoration: BoxDecoration(
                        color: Ex.safelight.withValues(alpha: 0.18),
                        borderRadius: BorderRadius.circular(20),
                      ),
                      child: Text('CORRECTION',
                          style: Ex.data.copyWith(color: Ex.safelight, fontSize: 8.5)),
                    ),
                  ],
                ],
              ),
            ],
            if (reason != null && reason.isNotEmpty) ...[
              const SizedBox(height: 8),
              Text(reason, style: Ex.reasonQuiet.copyWith(fontSize: 13)),
            ],
          ],
        ),
      ),
    );
  }
}

/// Faces in the photo that belong to nobody on the roster.
///
/// Reported rather than quietly dropped: somebody was in the room, and
/// pretending the system did not see them is worse than saying so.
class _Strangers extends StatelessWidget {
  final List<Map<String, dynamic>> faces;
  const _Strangers({required this.faces});

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SizedBox(height: 30),
        Row(
          children: [
            Container(
              width: 9,
              height: 9,
              decoration: BoxDecoration(
                color: Ex.safelight,
                shape: BoxShape.circle,
                boxShadow: [
                  BoxShadow(color: Ex.safelight.withValues(alpha: 0.6), blurRadius: 8),
                ],
              ),
            ),
            const SizedBox(width: 11),
            Text('Not on the roster', style: Ex.display.copyWith(fontSize: 21)),
            const SizedBox(width: 10),
            Text('${faces.length}', style: Ex.data.copyWith(fontSize: 12)),
          ],
        ),
        const SizedBox(height: 4),
        Padding(
          padding: const EdgeInsets.only(left: 18),
          child: Text(
            'Faces that matched nobody enrolled. Nobody was marked present for these.',
            style: Ex.reasonQuiet.copyWith(fontSize: 13),
          ),
        ),
        const SizedBox(height: 14),
        for (final face in faces)
          Padding(
            padding: const EdgeInsets.only(bottom: 9),
            child: Ex.glass(
              radius: 16,
              edge: Ex.safelight.withValues(alpha: 0.28),
              padding: const EdgeInsets.fromLTRB(16, 14, 16, 15),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Face ${(((face['face_id'] as num?)?.toInt() ?? 0) + 1).toString().padLeft(2, '0')}',
                    style: Ex.verdict.copyWith(fontSize: 15),
                  ),
                  if ((face['reason'] as String?)?.isNotEmpty ?? false) ...[
                    const SizedBox(height: 7),
                    Text('${face['reason']}',
                        style: Ex.reasonQuiet.copyWith(fontSize: 13)),
                  ],
                ],
              ),
            ),
          ),
      ],
    );
  }
}
