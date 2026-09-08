import 'package:flutter/material.dart';
import 'package:camera/camera.dart';
import 'screens/camera_screen.dart';
import 'screens/splash_screen.dart';
import 'screens/manage_students_screen.dart';
import 'theme/examination.dart';

import 'services/api_service.dart';

List<CameraDescription> cameras = [];

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  try {
    cameras = await availableCameras();
  } catch (e) {
    debugPrint('Error initializing cameras: $e');
  }
  await ApiService.init(); // Load custom URL if any
  runApp(const AttendanceApp());
}

class AttendanceApp extends StatelessWidget {
  const AttendanceApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Smart Attendance',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        brightness: Brightness.dark,
        scaffoldBackgroundColor: Ex.ink,
        colorScheme: ColorScheme.fromSeed(
          seedColor: Ex.safelight,
          brightness: Brightness.dark,
          surface: Ex.ink,
        ),
        useMaterial3: true,
      ),
      home: const SplashScreen(),
    );
  }
}

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Ex.ink,
      body: Ex.backdrop(
        child: SafeArea(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(24, 20, 24, 40),
            children: [
              Row(
                children: [
                  Text('SMART ATTENDANCE',
                      style: Ex.data.copyWith(fontSize: 10, letterSpacing: 2.4)),
                  const Spacer(),
                  IconButton(
                    icon: const Icon(Icons.tune_rounded, size: 20),
                    color: Ex.mute,
                    onPressed: () => _showServerSettings(context),
                    tooltip: 'Server address',
                  ),
                ],
              ),
              // Directly under the header, not further down: somebody opening
              // a shared link has no way to guess a key is needed, and the
              // alternative is their first tap failing with a bare 401.
              if (!ApiService.hasApiKey) ...[
                const SizedBox(height: 18),
                _NeedsKeyNotice(onOpenSettings: () => _showServerSettings(context)),
              ],
              const SizedBox(height: 34),
              Center(
                child: Ex.disc(
                  size: 96,
                  glow: Ex.safelight,
                  glowStrength: 0.7,
                  child: const Icon(Icons.face_retouching_natural_rounded,
                      color: Ex.bone, size: 40),
                ),
              ),
              const SizedBox(height: 32),
              Text(
                'One photograph.\nEvery face accounted for.',
                style: Ex.display,
              ),
              const SizedBox(height: 14),
              Text(
                'Faces the system cannot place are investigated one at a time, '
                'and it shows its working.',
                style: Ex.reasonQuiet,
              ),
              const SizedBox(height: 32),
              _Action(
                label: 'Mark attendance',
                blurb: 'Photograph the room, then watch the faces get worked through.',
                icon: Icons.camera_alt_rounded,
                accent: Ex.safelight,
                onTap: () => Navigator.push(
                  context,
                  MaterialPageRoute(builder: (_) => const CameraScreen()),
                ),
              ),
              const SizedBox(height: 14),
              _Action(
                label: 'Manage students',
                blurb: 'Add or remove the people on the roster.',
                icon: Icons.people_alt_rounded,
                accent: Ex.settled,
                onTap: () => Navigator.push(
                  context,
                  MaterialPageRoute(builder: (_) => const ManageStudentsScreen()),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _showServerSettings(BuildContext context) async {
    final controller = TextEditingController(text: ApiService.baseUrl);
    final keyController = TextEditingController(text: ApiService.apiKey);
    await showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF10314A),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(20),
          side: BorderSide(color: Ex.rule),
        ),
        title: Text('SERVER', style: Ex.dataStrong.copyWith(letterSpacing: 1.8)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Where the backend is running. On a laptop, the phone and the laptop '
              'must be on the same network; a deployed backend works from anywhere.',
              style: Ex.reasonQuiet.copyWith(fontSize: 13),
            ),
            const SizedBox(height: 18),
            TextField(
              controller: controller,
              style: Ex.reason.copyWith(fontSize: 14),
              decoration: Ex.field('Backend URL'),
            ),
            const SizedBox(height: 18),
            Text(
              'The access key the backend expects. Leave it empty only when running '
              'a local backend that has none set.',
              style: Ex.reasonQuiet.copyWith(fontSize: 13),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: keyController,
              style: Ex.reason.copyWith(fontSize: 14),
              obscureText: true,
              autocorrect: false,
              enableSuggestions: false,
              decoration: Ex.field('Access key'),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text('CANCEL', style: Ex.data.copyWith(fontSize: 11)),
          ),
          FilledButton(
            style: Ex.primaryButton,
            onPressed: () async {
              if (controller.text.isNotEmpty) {
                await ApiService.setBaseUrl(controller.text);
              }
              // Saved even when blank, so the key can be cleared for a local
              // backend that does not ask for one.
              await ApiService.setApiKey(keyController.text);
              if (ctx.mounted) Navigator.pop(ctx);
              // The home screen shows a notice while no key is set; it has to
              // be told the key just arrived.
              if (mounted) setState(() {});
            },
            child: Text('SAVE',
                style: Ex.dataStrong.copyWith(
                    color: const Color(0xFF3A2408), letterSpacing: 1.4)),
          ),
        ],
      ),
    );
  }
}

/// The two things this app does.
///
/// Each carries a glowing disc — the same shape the scan screen puts a face
/// inside — so the app reads as one object rather than a menu bolted onto a
/// feature.
/// Shown on the home screen while no access key is set.
///
/// Amber, not red: nothing is broken, something is simply not configured yet.
/// Red is reserved for a face that belongs to nobody on the roster.
class _NeedsKeyNotice extends StatelessWidget {
  final VoidCallback onOpenSettings;
  const _NeedsKeyNotice({required this.onOpenSettings});

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onOpenSettings,
      borderRadius: BorderRadius.circular(16),
      child: Container(
        padding: const EdgeInsets.fromLTRB(16, 14, 14, 14),
        decoration: BoxDecoration(
          color: Ex.safelight.withValues(alpha: 0.10),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: Ex.safelight.withValues(alpha: 0.35)),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Icon(Icons.key_rounded, size: 18, color: Ex.safelight),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('ACCESS KEY NEEDED',
                      style: Ex.data.copyWith(
                          fontSize: 10, letterSpacing: 1.8, color: Ex.safelight)),
                  const SizedBox(height: 6),
                  Text(
                    'This server is protected. Add the key in Settings before '
                    'marking attendance or opening the roster.',
                    style: Ex.reasonQuiet.copyWith(fontSize: 13),
                  ),
                ],
              ),
            ),
            const Icon(Icons.chevron_right_rounded, size: 20, color: Ex.safelight),
          ],
        ),
      ),
    );
  }
}

class _Action extends StatelessWidget {
  final String label;
  final String blurb;
  final IconData icon;
  final Color accent;
  final VoidCallback onTap;

  const _Action({
    required this.label,
    required this.blurb,
    required this.icon,
    required this.accent,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Ex.glass(
      radius: 20,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(20),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(18, 18, 16, 18),
            child: Row(
              children: [
                Ex.disc(
                  size: 52,
                  glow: accent,
                  glowStrength: 0.45,
                  child: Icon(icon, color: accent, size: 22),
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(label, style: Ex.verdict.copyWith(fontSize: 17)),
                      const SizedBox(height: 5),
                      Text(blurb, style: Ex.reasonQuiet.copyWith(fontSize: 13.5)),
                    ],
                  ),
                ),
                const SizedBox(width: 6),
                const Icon(Icons.chevron_right_rounded, size: 22, color: Ex.faint),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
