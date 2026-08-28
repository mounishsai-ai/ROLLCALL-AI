import 'dart:ui';

import 'package:flutter/material.dart';

/// Design tokens for the whole app.
///
/// The look: a deep petrol-to-navy gradient with soft blooms of light in it,
/// glass surfaces that let that gradient show through, and one warm amber
/// accent. Deliberately no purple or violet — a purple-to-pink gradient is the
/// single most generic thing a dark app can wear right now, and this one is
/// meant to look like somebody chose it.
///
/// Amber against teal is a complementary pair, so the accent separates from the
/// background at any brightness. It also carries meaning: amber is the colour
/// of the system working on something it has not settled yet.
class Ex {
  Ex._();

  // ── The room ────────────────────────────────────────────────
  static const ink = Color(0xFF081A2C); // deepest navy, the base
  static const _tealTop = Color(0xFF1B7D8C); // bright petrol-cyan
  static const _navyMid = Color(0xFF123457);
  static const _navyDeep = Color(0xFF050C18); // near-black

  /// Glass: a surface that is mostly the background, lifted slightly.
  static final bench = Colors.white.withValues(alpha: 0.06);
  static final benchRaised = Colors.white.withValues(alpha: 0.10);
  static final rule = Colors.white.withValues(alpha: 0.13);

  /// The bright top edge that makes a glass panel read as glass rather than
  /// as a flat grey box.
  static final sheen = Colors.white.withValues(alpha: 0.22);

  // ── Ink ─────────────────────────────────────────────────────
  static const bone = Color(0xFFEAF4F8); // cool white
  static const mute = Color(0xFF9DB4C4);
  static const faint = Color(0xFF64809A);

  // ── States ──────────────────────────────────────────────────
  /// Working on it. The one warm colour in the app.
  static const safelight = Color(0xFFFFB65C);

  /// Settled: this person is here.
  static const settled = Color(0xFF4FD6A0);

  /// A face belonging to nobody on the roster.
  static const outside = Color(0xFFFF8A7A);

  /// No answer reached. Cool and quiet on purpose — it must not read as a
  /// result.
  static const open = Color(0xFF9BB3C9);

  static Color spineFor(String state) => switch (state) {
        'present' => settled,
        'stranger' => outside,
        'unsure' => open,
        _ => safelight,
      };

  // ── Type ────────────────────────────────────────────────────
  // System sans throughout, leaning light and airy. No bundled or downloaded
  // fonts: a venue with bad wi-fi must not be able to change how this looks.

  /// What the system concluded, in words a teacher would use.
  static const reason = TextStyle(
    fontSize: 15,
    height: 1.5,
    color: bone,
    fontWeight: FontWeight.w400,
    letterSpacing: 0.1,
  );

  static const reasonQuiet = TextStyle(
    fontSize: 14,
    height: 1.5,
    color: mute,
    fontWeight: FontWeight.w400,
    letterSpacing: 0.1,
  );

  /// A verdict, or any display line. Light weight at large sizes is what keeps
  /// this from looking like a system dialog.
  static const verdict = TextStyle(
    fontSize: 17,
    height: 1.35,
    color: bone,
    fontWeight: FontWeight.w600,
    letterSpacing: 0.1,
  );

  static const display = TextStyle(
    fontSize: 30,
    height: 1.25,
    color: bone,
    fontWeight: FontWeight.w300,
    letterSpacing: -0.3,
  );

  /// Small caps for labels, tool names and metadata.
  static const data = TextStyle(
    fontSize: 11,
    height: 1.3,
    color: mute,
    fontWeight: FontWeight.w600,
    letterSpacing: 1.3,
  );

  static const dataStrong = TextStyle(
    fontSize: 12,
    height: 1.3,
    color: bone,
    fontWeight: FontWeight.w700,
    letterSpacing: 1.1,
  );

  static const tally = TextStyle(
    fontSize: 26,
    color: bone,
    fontWeight: FontWeight.w300,
    letterSpacing: -0.5,
  );

  /// Whether the viewer has asked the system to stop animating things.
  static bool stillness(BuildContext context) =>
      MediaQuery.maybeDisableAnimationsOf(context) ?? false;

  // ── The background ──────────────────────────────────────────

  /// Wraps a screen body in the gradient and its blooms.
  ///
  /// The gradient runs corner-to-corner rather than top-to-bottom: on a wide,
  /// short window (a desktop browser) a vertical ramp barely shows any of its
  /// own transition within the visible height and reads as one flat colour.
  /// Diagonal shows real movement regardless of the window's shape. Two soft
  /// radial blooms sit on top and are what actually read as colour to the
  /// eye — the ramp underneath is closer to a black canvas holding them.
  static Widget backdrop({required Widget child}) {
    return DecoratedBox(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [_tealTop, _navyMid, _navyDeep],
          stops: [0.0, 0.42, 1.0],
        ),
      ),
      child: Stack(
        children: [
          Positioned(
            top: -160,
            right: -140,
            child: _bloom(const Color(0xFF37E7CE), 420, 0.34),
          ),
          Positioned(
            bottom: -200,
            left: -160,
            child: _bloom(safelight, 440, 0.20),
          ),
          Positioned.fill(child: child),
        ],
      ),
    );
  }

  static Widget _bloom(Color color, double size, double strength) => IgnorePointer(
        child: Container(
          width: size,
          height: size,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            gradient: RadialGradient(
              colors: [color.withValues(alpha: strength), color.withValues(alpha: 0)],
            ),
          ),
        ),
      );

  // ── Glass ───────────────────────────────────────────────────

  /// A translucent panel.
  ///
  /// `blurred` costs real GPU work, so it is opt-in: a handful of focal
  /// elements get it, and everything in a scrolling list does not. Over this
  /// gradient the difference is nearly invisible, and dozens of live blur
  /// layers is the difference between a smooth demo and a stuttering one.
  static Widget glass({
    required Widget child,
    double radius = 18,
    bool blurred = false,
    Color? tint,
    Color? edge,
    EdgeInsetsGeometry? padding,
  }) {
    final panel = Container(
      padding: padding,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(radius),
        color: tint ?? bench,
        border: Border.all(color: edge ?? rule),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.22),
            blurRadius: 22,
            offset: const Offset(0, 8),
          ),
        ],
      ),
      child: child,
    );

    if (!blurred) return panel;
    return ClipRRect(
      borderRadius: BorderRadius.circular(radius),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 14, sigmaY: 14),
        child: panel,
      ),
    );
  }

  /// A glossy disc — the app's recurring shape.
  ///
  /// Used for a face on the timeline, for the shutter, and for the lamp. The
  /// off-centre highlight is what makes it read as a lit sphere instead of a
  /// flat circle.
  static Widget disc({
    required double size,
    Widget? child,
    Color glow = safelight,
    double glowStrength = 0.5,
    bool filled = true,
  }) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        gradient: filled
            ? RadialGradient(
                center: const Alignment(-0.35, -0.45),
                radius: 1.05,
                colors: [
                  Colors.white.withValues(alpha: 0.26),
                  Colors.white.withValues(alpha: 0.06),
                ],
              )
            : null,
        border: Border.all(color: glow.withValues(alpha: 0.75), width: 1.4),
        boxShadow: [
          BoxShadow(
            color: glow.withValues(alpha: glowStrength * 0.55),
            blurRadius: size * 0.55,
            spreadRadius: size * 0.04,
          ),
        ],
      ),
      clipBehavior: Clip.antiAlias,
      child: child,
    );
  }

  // ── Shared furniture ────────────────────────────────────────

  static AppBar bar(String title, {List<Widget>? actions}) => AppBar(
        backgroundColor: Colors.transparent,
        surfaceTintColor: Colors.transparent,
        foregroundColor: bone,
        elevation: 0,
        centerTitle: false,
        title: Text(title.toUpperCase(), style: dataStrong.copyWith(letterSpacing: 2)),
        actions: actions,
      );

  /// The one filled button in the app: warm, so the primary action is the
  /// brightest thing on the screen.
  static ButtonStyle get primaryButton => FilledButton.styleFrom(
        backgroundColor: safelight,
        foregroundColor: const Color(0xFF3A2408),
        disabledBackgroundColor: Colors.white.withValues(alpha: 0.10),
        disabledForegroundColor: faint,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        padding: const EdgeInsets.symmetric(vertical: 17),
        elevation: 0,
      );

  static InputDecoration field(String label) => InputDecoration(
        labelText: label.toUpperCase(),
        labelStyle: data.copyWith(fontSize: 10),
        floatingLabelStyle: data.copyWith(fontSize: 10, color: safelight),
        filled: true,
        fillColor: bench,
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 18),
        border: _border(rule),
        enabledBorder: _border(rule),
        focusedBorder: _border(safelight.withValues(alpha: 0.8)),
      );

  static OutlineInputBorder _border(Color color) => OutlineInputBorder(
        borderRadius: BorderRadius.circular(14),
        borderSide: BorderSide(color: color),
      );

  /// Tells the user something happened, in the interface's voice.
  static void say(BuildContext context, String message, {bool bad = false}) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          message,
          style: reason.copyWith(fontSize: 14, color: const Color(0xFF08202E)),
        ),
        backgroundColor: bad ? outside : settled,
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      ),
    );
  }
}
