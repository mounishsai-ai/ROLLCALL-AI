import 'dart:async';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

import '../models/scan_event.dart';
import '../services/api_service.dart';
import '../theme/examination.dart';
import 'result_screen.dart';

/// Watches a scan think.
///
/// The photo is uploaded, then the backend's reasoning is pulled down step by
/// step and shown as it arrives. Faces are examined in parallel, so several
/// cards fill in at once; each keeps its own thread of observations, decisions
/// and tool results until it reaches a verdict.
class ScanScreen extends StatefulWidget {
  final XFile image;
  const ScanScreen({super.key, required this.image});

  @override
  State<ScanScreen> createState() => _ScanScreenState();
}

class _ScanScreenState extends State<ScanScreen> {
  final ScanProgress _progress = ScanProgress();
  final ScrollController _scroll = ScrollController();
  final Stopwatch _clock = Stopwatch();

  Timer? _ticker;
  String? _jobId;
  String? _fatal;
  bool _polling = false;
  int _tick = 0;

  @override
  void initState() {
    super.initState();
    _begin();
  }

  @override
  void dispose() {
    _ticker?.cancel();
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _begin() async {
    try {
      final jobId = await ApiService.startAgenticAttendance(widget.image);
      if (!mounted) return;
      setState(() {
        _jobId = jobId;
        _clock.start();
      });
      // One timer drives both the clock and the polling: the clock needs to
      // move smoothly, the network does not need to be asked that often.
      _ticker = Timer.periodic(const Duration(milliseconds: 200), (_) {
        if (!mounted) return;
        setState(() => _tick++);
        if (_tick % 3 == 0) _poll();
      });
    } catch (e) {
      if (mounted) setState(() => _fatal = _friendly(e));
    }
  }

  Future<void> _poll() async {
    if (_polling || _jobId == null) return;
    _polling = true;
    try {
      final data = await ApiService.fetchScanProgress(_jobId!, since: _progress.cursor);
      if (!mounted) return;

      final incoming = (data['events'] as List? ?? const [])
          .whereType<Map<String, dynamic>>()
          .map(ScanEvent.fromJson)
          .toList();

      setState(() {
        _progress.ingest(incoming);
        _progress.cursor = (data['cursor'] as num?)?.toInt() ?? _progress.cursor;
        _progress.status = data['job_status'] as String? ?? _progress.status;
        _progress.error = data['error'] as String?;
        _progress.result = data['result'] as Map<String, dynamic>?;
      });

      if (incoming.isNotEmpty) _followTheStream();

      if (!_progress.isRunning) {
        _ticker?.cancel();
        _clock.stop();
      }
    } catch (e) {
      // A dropped poll is not a failed scan — the work continues on the
      // server and the cursor means nothing is missed on the next attempt.
      debugPrint('scan poll failed: $e');
    } finally {
      _polling = false;
    }
  }

  /// Keeps the newest reasoning in view, unless the viewer has scrolled back
  /// to read something — then it leaves them where they are.
  void _followTheStream() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scroll.hasClients) return;
      final position = _scroll.position;
      if (position.maxScrollExtent - position.pixels > 240) return;
      position.animateTo(
        position.maxScrollExtent,
        duration: const Duration(milliseconds: 260),
        curve: Curves.easeOut,
      );
    });
  }

  String _friendly(Object e) {
    final text = e.toString();
    if (text.contains('SocketException') || text.contains('Connection')) {
      return 'Could not reach the server. Check that the backend is running and that the address in Settings is right.';
    }
    return text.replaceFirst('Exception: ', '');
  }

  String get _elapsed {
    final ms = _clock.elapsedMilliseconds;
    final seconds = ms ~/ 1000;
    return '${(seconds ~/ 60).toString().padLeft(2, '0')}:'
        '${(seconds % 60).toString().padLeft(2, '0')}.'
        '${((ms % 1000) ~/ 100)}';
  }

  @override
  Widget build(BuildContext context) {
    final done = !_progress.isRunning && _jobId != null;

    return Scaffold(
      backgroundColor: Ex.ink,
      body: Ex.backdrop(
        child: SafeArea(
          child: Column(
            children: [
              _Header(
                running: _progress.isRunning && _fatal == null,
                elapsed: _elapsed,
                onClose: () => Navigator.of(context).pop(),
              ),
              _Ledger(progress: _progress),
              Expanded(child: _body()),
              if (done && _progress.result != null)
                _Footer(result: _progress.result!, onOpen: _openRegister),
            ],
          ),
        ),
      ),
    );
  }

  void _openRegister() {
    Navigator.pushReplacement(
      context,
      MaterialPageRoute(builder: (_) => ResultScreen(result: _progress.result!)),
    );
  }

  Widget _body() {
    if (_fatal != null) return _Trouble(message: _fatal!);
    if (_progress.error != null) return _Trouble(message: _progress.error!);

    if (_progress.stream.isEmpty) {
      return _Waiting(uploaded: _jobId != null);
    }

    return ReasoningTrace(progress: _progress, controller: _scroll);
  }
}

/// The reasoning itself, split out from the screen so it can be rendered
/// without a server: [ScanScreen] starts a scan the moment it is built, which
/// makes the layout untestable while it lives inside.
class ReasoningTrace extends StatelessWidget {
  final ScanProgress progress;
  final ScrollController? controller;

  const ReasoningTrace({super.key, required this.progress, this.controller});

  @override
  Widget build(BuildContext context) {
    // Chronological order, but with each face's steps collected into the card
    // where that face first appeared.
    final blocks = <Widget>[];
    final placed = <int>{};
    for (final event in progress.stream) {
      final faceId = event.faceId;
      if (faceId == null) {
        blocks.add(_ScanNote(event: event));
      } else if (placed.add(faceId)) {
        blocks.add(_CaseCard(record: progress.cases[faceId]!));
      }
    }

    return ListView(
      controller: controller,
      padding: const EdgeInsets.fromLTRB(18, 10, 18, 34),
      children: blocks,
    );
  }
}

// ──────────────────────────────────────────────────────────────
//  Header
// ──────────────────────────────────────────────────────────────

class _Header extends StatelessWidget {
  final bool running;
  final String elapsed;
  final VoidCallback onClose;

  const _Header({required this.running, required this.elapsed, required this.onClose});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 10, 8, 6),
      child: Row(
        children: [
          _Safelight(lit: running),
          const SizedBox(width: 12),
          Text(
            running ? 'EXAMINING' : 'EXAMINATION COMPLETE',
            style: Ex.dataStrong.copyWith(
              color: running ? Ex.safelight : Ex.bone,
              letterSpacing: 1.8,
            ),
          ),
          const Spacer(),
          Text(elapsed,
              style: Ex.data.copyWith(fontSize: 13, fontWeight: FontWeight.w400)),
          IconButton(
            onPressed: onClose,
            icon: const Icon(Icons.close_rounded, size: 20),
            color: Ex.mute,
            tooltip: 'Stop watching',
          ),
        ],
      ),
    );
  }
}

/// The lamp. It breathes while something is being examined.
class _Safelight extends StatefulWidget {
  final bool lit;
  const _Safelight({required this.lit});

  @override
  State<_Safelight> createState() => _SafelightState();
}

class _SafelightState extends State<_Safelight> with SingleTickerProviderStateMixin {
  // Built eagerly, not with `late final`. A lazily-created controller that is
  // never touched while the widget lives gets created for the first time by
  // dispose(), which builds a Ticker against a deactivated element and throws.
  // That happens exactly when nothing is animating — a finished scan.
  late final AnimationController _c;

  @override
  void initState() {
    super.initState();
    _c = AnimationController(vsync: this, duration: const Duration(milliseconds: 1100));
    if (widget.lit) _c.repeat(reverse: true);
  }

  @override
  void didUpdateWidget(covariant _Safelight old) {
    super.didUpdateWidget(old);
    if (widget.lit && !_c.isAnimating) {
      _c.repeat(reverse: true);
    } else if (!widget.lit) {
      _c.stop();
      _c.value = 0;
    }
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final color = widget.lit ? Ex.safelight : Ex.settled;
    if (!widget.lit || Ex.stillness(context)) return _dot(color, 1);
    return AnimatedBuilder(
      animation: _c,
      builder: (_, _) => _dot(color, 0.35 + 0.65 * _c.value),
    );
  }

  Widget _dot(Color color, double strength) => Container(
        width: 10,
        height: 10,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: color.withValues(alpha: strength),
          boxShadow: [
            BoxShadow(
              color: color.withValues(alpha: strength * 0.6),
              blurRadius: 14,
              spreadRadius: 3,
            ),
          ],
        ),
      );
}

// ──────────────────────────────────────────────────────────────
//  Ledger
// ──────────────────────────────────────────────────────────────

class _Ledger extends StatelessWidget {
  final ScanProgress progress;
  const _Ledger({required this.progress});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(18, 6, 18, 10),
      child: Ex.glass(
        radius: 18,
        blurred: true,
        padding: const EdgeInsets.symmetric(vertical: 15),
        child: Row(
          children: [
            _cell('FACES', progress.cases.length.toString(), Ex.bone),
            _divider(),
            _cell('SETTLED', progress.settledCount.toString(), Ex.settled),
            _divider(),
            _cell('OPEN', progress.openCount.toString(), Ex.safelight),
          ],
        ),
      ),
    );
  }

  Widget _divider() => Container(width: 1, height: 28, color: Ex.rule);

  Widget _cell(String label, String value, Color color) => Expanded(
        child: Column(
          children: [
            Text(value, style: Ex.tally.copyWith(color: color)),
            const SizedBox(height: 3),
            Text(label, style: Ex.data.copyWith(fontSize: 9, letterSpacing: 1.6)),
          ],
        ),
      );
}

// ──────────────────────────────────────────────────────────────
//  Scan-level narration
// ──────────────────────────────────────────────────────────────

/// Notes about the scan as a whole. A small node on the same thread the faces
/// hang from, so the whole run reads as one timeline.
class _ScanNote extends StatelessWidget {
  final ScanEvent event;
  const _ScanNote({required this.event});

  @override
  Widget build(BuildContext context) {
    return _Arrival(
      seq: event.seq,
      child: IntrinsicHeight(
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _Thread(
              node: Container(
                width: 12,
                height: 12,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: Ex.mute.withValues(alpha: 0.85),
                  border: Border.all(color: Ex.rule),
                ),
              ),
              nodeSize: 12,
            ),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.only(left: 14, top: 14, bottom: 20),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(event.title,
                              style: Ex.verdict.copyWith(fontSize: 16)),
                        ),
                        Text('${event.ts.toStringAsFixed(1)}s',
                            style: Ex.data
                                .copyWith(fontSize: 10, fontWeight: FontWeight.w400)),
                      ],
                    ),
                    if (event.detail.isNotEmpty) ...[
                      const SizedBox(height: 6),
                      Text(event.detail, style: Ex.reasonQuiet.copyWith(fontSize: 13.5)),
                    ],
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// The vertical line every node hangs from.
class _Thread extends StatelessWidget {
  final Widget node;
  final double nodeSize;
  const _Thread({required this.node, required this.nodeSize});

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 56,
      child: Stack(
        alignment: Alignment.topCenter,
        children: [
          Positioned(
            top: 0,
            bottom: 0,
            child: Container(width: 1, color: Ex.rule),
          ),
          Padding(padding: const EdgeInsets.only(top: 10), child: node),
        ],
      ),
    );
  }
}

// ──────────────────────────────────────────────────────────────
//  Case card — the signature element
// ──────────────────────────────────────────────────────────────

/// One face's investigation: a glowing disc holding the face, hung on the
/// thread, with the reasoning in a glass panel beside it.
///
/// The disc's ring is amber and breathing while the examination is live, and
/// settles to a fixed colour when the verdict lands. Several breathe at once,
/// because faces really are examined in parallel.
class _CaseCard extends StatelessWidget {
  final FaceCase record;
  const _CaseCard({required this.record});

  @override
  Widget build(BuildContext context) {
    final accent = Ex.spineFor(record.state);
    final working = record.isWorking;

    return _Arrival(
      seq: record.steps.first.seq,
      child: IntrinsicHeight(
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _Thread(
              nodeSize: 46,
              node: _FaceNode(record: record, accent: accent, breathing: working),
            ),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.only(left: 14, top: 6, bottom: 16),
                child: Ex.glass(
                  radius: 18,
                  tint: working ? Ex.benchRaised : Ex.bench,
                  edge: working ? accent.withValues(alpha: 0.35) : Ex.rule,
                  padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Expanded(
                            child: Text(
                              'Face ${(record.faceId + 1).toString().padLeft(2, '0')}',
                              style: Ex.verdict.copyWith(fontSize: 15),
                            ),
                          ),
                          Container(
                            padding:
                                const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
                            decoration: BoxDecoration(
                              color: accent.withValues(alpha: 0.16),
                              borderRadius: BorderRadius.circular(20),
                            ),
                            child: Text(
                              record.stateLabel,
                              style: Ex.data.copyWith(color: accent, fontSize: 9),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 14),
                      for (int i = 0; i < record.steps.length; i++)
                        _Step(
                          event: record.steps[i],
                          accent: accent,
                          last: i == record.steps.length - 1,
                        ),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _FaceNode extends StatefulWidget {
  final FaceCase record;
  final Color accent;
  final bool breathing;

  const _FaceNode({
    required this.record,
    required this.accent,
    required this.breathing,
  });

  @override
  State<_FaceNode> createState() => _FaceNodeState();
}

class _FaceNodeState extends State<_FaceNode> with SingleTickerProviderStateMixin {
  // Eager for the same reason as _Safelight: a settled face never animates, so
  // a lazy controller would first be created inside dispose() and throw.
  late final AnimationController _c;

  @override
  void initState() {
    super.initState();
    _c = AnimationController(vsync: this, duration: const Duration(milliseconds: 1500));
    if (widget.breathing) _c.repeat(reverse: true);
  }

  @override
  void didUpdateWidget(covariant _FaceNode old) {
    super.didUpdateWidget(old);
    if (widget.breathing && !_c.isAnimating) {
      _c.repeat(reverse: true);
    } else if (!widget.breathing) {
      _c.stop();
    }
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  Widget _face() {
    final thumb = widget.record.thumb;
    if (thumb != null) {
      return Image.memory(thumb, fit: BoxFit.cover, gaplessPlayback: true);
    }
    return const Icon(Icons.person_outline_rounded, color: Ex.faint, size: 20);
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.breathing || Ex.stillness(context)) {
      return Ex.disc(
        size: 46,
        glow: widget.accent,
        glowStrength: 0.5,
        filled: false,
        child: _face(),
      );
    }
    return AnimatedBuilder(
      animation: _c,
      builder: (_, _) => Ex.disc(
        size: 46,
        glow: widget.accent,
        glowStrength: 0.3 + 0.7 * _c.value,
        filled: false,
        child: _face(),
      ),
    );
  }
}

/// One observation, decision, tool result or verdict inside a case card.
class _Step extends StatelessWidget {
  final ScanEvent event;
  final Color accent;
  final bool last;

  const _Step({required this.event, required this.accent, required this.last});

  Color get _markerColor => switch (event.kind) {
        'observe' => Ex.mute,
        'think' => Ex.safelight,
        'tool' => event.outcome == 'error' ? Ex.outside : Ex.bone,
        'verdict' => accent,
        _ => Ex.mute,
      };

  String get _label => switch (event.kind) {
        'observe' => 'OBSERVED',
        'think' => 'DECISION',
        'tool' => _toolLabel,
        'verdict' => 'VERDICT',
        _ => event.kind.toUpperCase(),
      };

  String get _toolLabel => switch (event.tool) {
        'rescan_at_higher_resolution' => 'RE-CROP',
        'gemini_identify' => 'SECOND OPINION',
        _ => 'RESULT',
      };

  @override
  Widget build(BuildContext context) {
    final isVerdict = event.kind == 'verdict';

    return Padding(
      padding: EdgeInsets.only(bottom: last ? 0 : 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 6,
                height: 6,
                decoration: BoxDecoration(
                  color: _markerColor,
                  shape: BoxShape.circle,
                  boxShadow: [
                    BoxShadow(
                        color: _markerColor.withValues(alpha: 0.6), blurRadius: 6),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              Text(_label, style: Ex.data.copyWith(color: _markerColor, fontSize: 9.5)),
              if (event.corrected) ...[
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
              const Spacer(),
              Text('${event.ts.toStringAsFixed(1)}s',
                  style:
                      Ex.data.copyWith(fontSize: 9.5, fontWeight: FontWeight.w400)),
            ],
          ),
          const SizedBox(height: 7),
          Padding(
            padding: const EdgeInsets.only(left: 14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  event.title,
                  style: isVerdict
                      ? Ex.verdict.copyWith(color: accent, fontSize: 15.5)
                      : Ex.reason.copyWith(fontSize: 14.5),
                ),
                if (event.detail.isNotEmpty) ...[
                  const SizedBox(height: 5),
                  Text(event.detail, style: Ex.reasonQuiet.copyWith(fontSize: 13)),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// ──────────────────────────────────────────────────────────────
//  Arrival animation
// ──────────────────────────────────────────────────────────────

/// Fades and lifts a block in the first time it appears, so new reasoning
/// reads as arriving rather than as having always been there.
class _Arrival extends StatefulWidget {
  final int seq;
  final Widget child;
  const _Arrival({required this.seq, required this.child});

  @override
  State<_Arrival> createState() => _ArrivalState();
}

class _ArrivalState extends State<_Arrival> with SingleTickerProviderStateMixin {
  // Eager: with reduced motion on, build() never touches the controller, so a
  // lazy one would be created for the first time by dispose().
  late final AnimationController _c;

  @override
  void initState() {
    super.initState();
    _c = AnimationController(vsync: this, duration: const Duration(milliseconds: 320))
      ..forward();
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (Ex.stillness(context)) return widget.child;
    final curve = CurvedAnimation(parent: _c, curve: Curves.easeOutCubic);
    return FadeTransition(
      opacity: curve,
      child: SlideTransition(
        position: Tween(begin: const Offset(0, 0.05), end: Offset.zero).animate(curve),
        child: widget.child,
      ),
    );
  }
}

// ──────────────────────────────────────────────────────────────
//  Waiting, trouble, footer
// ──────────────────────────────────────────────────────────────

class _Waiting extends StatelessWidget {
  final bool uploaded;
  const _Waiting({required this.uploaded});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(36),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Ex.disc(
              size: 78,
              glow: Ex.safelight,
              glowStrength: 0.6,
              child: const Icon(Icons.center_focus_weak_rounded,
                  color: Ex.bone, size: 32),
            ),
            const SizedBox(height: 26),
            Text(
              uploaded ? 'Looking at the photograph' : 'Sending the photograph',
              style: Ex.display.copyWith(fontSize: 21),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 10),
            Text(
              uploaded
                  ? 'Every face is found first, then measured against the students on the roster. The reasoning appears here as it happens.'
                  : 'This takes a moment on a large photo.',
              style: Ex.reasonQuiet,
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }
}

class _Trouble extends StatelessWidget {
  final String message;
  const _Trouble({required this.message});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(26),
        child: Ex.glass(
          radius: 20,
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('THE SCAN STOPPED',
                  style: Ex.data.copyWith(color: Ex.outside, letterSpacing: 1.6)),
              const SizedBox(height: 12),
              Text(message, style: Ex.reason),
            ],
          ),
        ),
      ),
    );
  }
}

class _Footer extends StatelessWidget {
  final Map<String, dynamic> result;
  final VoidCallback onOpen;

  const _Footer({required this.result, required this.onOpen});

  @override
  Widget build(BuildContext context) {
    final present = (result['present'] as List?)?.length ?? 0;
    final unsure = (result['unsure'] as List?)?.length ?? 0;
    final strangers = (result['unknown_faces'] as List?)?.length ?? 0;

    final notes = <String>[
      '$present marked present',
      if (unsure > 0) '$unsure left for you',
      if (strangers > 0) '$strangers face${strangers == 1 ? '' : 's'} not on the roster',
    ];

    return Padding(
      padding: const EdgeInsets.fromLTRB(18, 6, 18, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(notes.join('  ·  '),
              style: Ex.reasonQuiet, textAlign: TextAlign.center),
          const SizedBox(height: 12),
          FilledButton(
            style: Ex.primaryButton,
            onPressed: onOpen,
            child: Text('OPEN THE REGISTER',
                style: Ex.dataStrong
                    .copyWith(color: const Color(0xFF3A2408), letterSpacing: 1.6)),
          ),
        ],
      ),
    );
  }
}
