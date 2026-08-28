import 'package:flutter/material.dart';
import '../main.dart';
import '../theme/examination.dart';

/// The safelight coming on.
///
/// Deliberately brief. A splash that holds the room for three and a half
/// seconds is time a person spends waiting to use the app, and at a live demo
/// it is time spent watching nothing happen.
class SplashScreen extends StatefulWidget {
  const SplashScreen({super.key});

  @override
  State<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends State<SplashScreen>
    with SingleTickerProviderStateMixin {
  // Eager, so dispose() can never be the first thing to touch it.
  late final AnimationController _c;

  @override
  void initState() {
    super.initState();
    _c = AnimationController(vsync: this, duration: const Duration(milliseconds: 900))
      ..forward();
    Future.delayed(const Duration(milliseconds: 1300), () {
      if (!mounted) return;
      Navigator.of(context).pushReplacement(
        PageRouteBuilder(
          pageBuilder: (_, _, _) => const HomeScreen(),
          transitionsBuilder: (_, animation, _, child) =>
              FadeTransition(opacity: animation, child: child),
          transitionDuration: const Duration(milliseconds: 420),
        ),
      );
    });
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final glow = CurvedAnimation(parent: _c, curve: Curves.easeOutCubic);

    return Scaffold(
      backgroundColor: Ex.ink,
      body: Ex.backdrop(
        child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            AnimatedBuilder(
              animation: glow,
              builder: (_, _) => Opacity(
                opacity: glow.value,
                child: Ex.disc(
                  size: 104,
                  glow: Ex.safelight,
                  glowStrength: glow.value,
                  child: const Icon(Icons.face_retouching_natural_rounded,
                      color: Ex.bone, size: 42),
                ),
              ),
            ),
            const SizedBox(height: 34),
            FadeTransition(
              opacity: glow,
              child: Column(
                children: [
                  Text('Smart Attendance',
                      style: Ex.display.copyWith(fontSize: 26)),
                  const SizedBox(height: 10),
                  Text(
                    'ONE PHOTOGRAPH  ·  EVERY FACE',
                    style: Ex.data.copyWith(fontSize: 9.5, letterSpacing: 2.2),
                  ),
                ],
              ),
            ),
          ],
        ),
        ),
      ),
    );
  }
}
