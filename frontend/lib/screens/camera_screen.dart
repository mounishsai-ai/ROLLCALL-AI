import 'package:flutter/material.dart';
import 'package:camera/camera.dart';
import 'package:image_picker/image_picker.dart';
import 'scan_screen.dart';
import '../main.dart';
import '../theme/examination.dart';

/// Take the photograph, or choose one already taken.
class CameraScreen extends StatefulWidget {
  const CameraScreen({super.key});

  @override
  State<CameraScreen> createState() => _CameraScreenState();
}

class _CameraScreenState extends State<CameraScreen> {
  CameraController? _controller;
  bool _isCameraReady = false;

  // Pinch-to-zoom. Bounds come from the device itself: some cameras (and most
  // browsers, on web) do not support zoom at all, in which case both come back
  // as 1.0 and the gesture becomes a no-op rather than an error.
  double _minZoom = 1.0;
  double _maxZoom = 1.0;
  double _zoom = 1.0;
  double _zoomAtGestureStart = 1.0;

  @override
  void initState() {
    super.initState();
    _initCamera();
  }

  Future<void> _initCamera() async {
    if (cameras.isEmpty) return;
    try {
      _controller = CameraController(cameras[0], ResolutionPreset.high);
      await _controller!.initialize();
      await _loadZoomRange();
      if (mounted) setState(() => _isCameraReady = true);
    } catch (e) {
      if (mounted) Ex.say(context, 'The camera would not start. $e', bad: true);
    }
  }

  Future<void> _loadZoomRange() async {
    try {
      _minZoom = await _controller!.getMinZoomLevel();
      _maxZoom = await _controller!.getMaxZoomLevel();
    } catch (_) {
      // Zoom isn't available on this device/browser. Leave both at 1.0 so the
      // pinch gesture has nothing to move and quietly does nothing.
      _minZoom = 1.0;
      _maxZoom = 1.0;
    }
    _zoom = _minZoom;
  }

  void _onScaleStart(ScaleStartDetails _) {
    _zoomAtGestureStart = _zoom;
  }

  void _onScaleUpdate(ScaleUpdateDetails details) {
    if (_controller == null || _maxZoom <= _minZoom) return;
    final next = (_zoomAtGestureStart * details.scale).clamp(_minZoom, _maxZoom);
    if (next == _zoom) return;
    setState(() => _zoom = next);
    _controller!.setZoomLevel(_zoom);
  }

  @override
  void dispose() {
    _controller?.dispose();
    super.dispose();
  }

  Future<void> _capture() async {
    if (_controller == null || !_controller!.value.isInitialized) return;
    try {
      final photo = await _controller!.takePicture();
      _examine(photo);
    } catch (e) {
      if (mounted) Ex.say(context, 'The photo could not be taken. $e', bad: true);
    }
  }

  Future<void> _pickFromGallery() async {
    final image = await ImagePicker()
        .pickImage(source: ImageSource.gallery, imageQuality: 90);
    if (image != null) _examine(image);
  }

  void _examine(XFile image) {
    if (!mounted) return;
    // The scan screen owns the upload and the whole investigation from here,
    // so the reasoning can be watched while it happens.
    Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => ScanScreen(image: image)),
    );
  }

  Future<void> _flip() async {
    if (cameras.length < 2) return;
    final facing = _controller?.description.lensDirection;
    final next = cameras.firstWhere(
      (c) => c.lensDirection != facing,
      orElse: () => cameras[0],
    );
    await _controller?.dispose();
    _controller = CameraController(next, ResolutionPreset.high);
    await _controller!.initialize();
    await _loadZoomRange();
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Ex.ink,
      extendBodyBehindAppBar: true,
      appBar: Ex.bar('Photograph the room'),
      body: Ex.backdrop(
        child: Column(
        children: [
          Expanded(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 100, 16, 12),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(24),
                child: GestureDetector(
                  onScaleStart: _isCameraReady ? _onScaleStart : null,
                  onScaleUpdate: _isCameraReady ? _onScaleUpdate : null,
                  child: Stack(
                  children: [
                    if (_isCameraReady && _controller != null)
                      // CameraPreview already wraps itself in an AspectRatio
                      // that accounts for sensor orientation. Forcing a second,
                      // guessed aspect ratio on top of it (as this used to do,
                      // via FittedBox + a manually swapped width/height) fights
                      // the plugin's own math and over-crops — it reads as the
                      // camera being zoomed in far past the real field of view.
                      // Centering it and letting it size itself is correct.
                      Positioned.fill(
                        child: Center(child: CameraPreview(_controller!)),
                      )
                    else
                      Positioned.fill(
                        child: Ex.glass(
                          radius: 24,
                          child: Center(
                            child: Padding(
                              padding: const EdgeInsets.all(28),
                              child: Text(
                                cameras.isEmpty
                                    ? 'No camera on this device. Choose a photo instead.'
                                    : 'Starting the camera',
                                style: Ex.reasonQuiet,
                                textAlign: TextAlign.center,
                              ),
                            ),
                          ),
                        ),
                      ),
                    if (_isCameraReady)
                      Positioned.fill(child: CustomPaint(painter: _FramePainter())),
                    if (_isCameraReady && _maxZoom > _minZoom)
                      Positioned(
                        right: 14,
                        bottom: 14,
                        child: _ZoomBadge(zoom: _zoom),
                      ),
                  ],
                  ),
                ),
              ),
            ),
          ),
          Container(
            padding: const EdgeInsets.fromLTRB(24, 4, 24, 26),
            child: Column(
              children: [
                Text(
                  'Get every face in frame. Faces at the back are fine — they get a closer look.',
                  style: Ex.reasonQuiet.copyWith(fontSize: 13),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 20),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    _SideButton(
                      icon: Icons.photo_library_outlined,
                      label: 'CHOOSE',
                      onTap: _pickFromGallery,
                    ),
                    GestureDetector(
                      onTap: _isCameraReady ? _capture : null,
                      child: Ex.disc(
                        size: 76,
                        glow: Ex.safelight,
                        glowStrength: _isCameraReady ? 0.8 : 0.15,
                        child: Icon(
                          Icons.camera_alt_rounded,
                          color: _isCameraReady ? Ex.bone : Ex.faint,
                          size: 30,
                        ),
                      ),
                    ),
                    _SideButton(
                      icon: Icons.cameraswitch_outlined,
                      label: 'FLIP',
                      onTap: cameras.length > 1 ? _flip : null,
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
        ),
      ),
    );
  }
}

class _SideButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback? onTap;

  const _SideButton({required this.icon, required this.label, this.onTap});

  @override
  Widget build(BuildContext context) {
    final color = onTap == null ? Ex.faint : Ex.mute;
    return GestureDetector(
      onTap: onTap,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 50,
            height: 50,
            decoration: BoxDecoration(
              color: Ex.bench,
              border: Border.all(color: Ex.rule),
              borderRadius: BorderRadius.circular(16),
            ),
            child: Icon(icon, color: color, size: 20),
          ),
          const SizedBox(height: 7),
          Text(label, style: Ex.data.copyWith(fontSize: 9, color: color)),
        ],
      ),
    );
  }
}

/// The current zoom level, shown only while more than one level is possible.
class _ZoomBadge extends StatelessWidget {
  final double zoom;
  const _ZoomBadge({required this.zoom});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.45),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Text('${zoom.toStringAsFixed(1)}×',
          style: Ex.dataStrong.copyWith(fontSize: 11, letterSpacing: 0.5)),
    );
  }
}

/// Corner marks, like a viewfinder. Deliberately thin — the photograph is the
/// subject, not the overlay.
class _FramePainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = Ex.safelight.withValues(alpha: 0.85)
      ..strokeWidth = 2
      ..style = PaintingStyle.stroke;

    const corner = 26.0;
    const margin = 26.0;
    final rect = Rect.fromLTRB(
      margin,
      margin,
      size.width - margin,
      size.height - margin,
    );

    for (final (origin, dx, dy) in [
      (rect.topLeft, 1.0, 1.0),
      (rect.topRight, -1.0, 1.0),
      (rect.bottomLeft, 1.0, -1.0),
      (rect.bottomRight, -1.0, -1.0),
    ]) {
      canvas.drawLine(origin, origin + Offset(corner * dx, 0), paint);
      canvas.drawLine(origin, origin + Offset(0, corner * dy), paint);
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}
