import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

import '../services/api_service.dart';
import '../theme/examination.dart';

/// Add one student to the roster.
class RegisterScreen extends StatefulWidget {
  const RegisterScreen({super.key});

  @override
  State<RegisterScreen> createState() => _RegisterScreenState();
}

class _RegisterScreenState extends State<RegisterScreen> {
  final _nameController = TextEditingController();
  final _regController = TextEditingController();
  XFile? _photo;
  bool _saving = false;

  @override
  void dispose() {
    _nameController.dispose();
    _regController.dispose();
    super.dispose();
  }

  Future<void> _pickImage() async {
    final image = await ImagePicker()
        .pickImage(source: ImageSource.gallery, imageQuality: 90);
    if (image != null) setState(() => _photo = image);
  }

  Future<void> _save() async {
    if (_nameController.text.isEmpty || _regController.text.isEmpty || _photo == null) {
      Ex.say(context, 'Add a name, a registration number, and one photo.', bad: true);
      return;
    }
    setState(() => _saving = true);
    try {
      await ApiService.registerStudent(
        name: _nameController.text,
        regNumber: _regController.text,
        imageFile: _photo!,
      );
      if (!mounted) return;
      Ex.say(context, '${_nameController.text} added. The face is being processed.');
      Navigator.pop(context);
    } catch (e) {
      if (!mounted) return;
      Ex.say(context, 'Could not add them. ${e.toString().replaceFirst('Exception: ', '')}',
          bad: true);
    }
    if (mounted) setState(() => _saving = false);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Ex.ink,
      extendBodyBehindAppBar: true,
      appBar: Ex.bar('Add a student'),
      body: Ex.backdrop(
        child: ListView(
        padding: const EdgeInsets.fromLTRB(24, 110, 24, 40),
        children: [
          Center(child: _photoWell()),
          const SizedBox(height: 12),
          Text(
            'One clear, front-facing photo with exactly one face in it. '
            'Two faces will be rejected — otherwise the wrong person gets bound to this name.',
            style: Ex.reasonQuiet.copyWith(fontSize: 13),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 32),
          TextField(
            controller: _nameController,
            style: Ex.reason.copyWith(fontSize: 15),
            decoration: Ex.field('Full name'),
            textCapitalization: TextCapitalization.words,
          ),
          const SizedBox(height: 14),
          TextField(
            controller: _regController,
            style: Ex.reason.copyWith(fontSize: 15),
            decoration: Ex.field('Registration number'),
          ),
          const SizedBox(height: 32),
          FilledButton(
            style: Ex.primaryButton,
            onPressed: _saving ? null : _save,
            child: _saving
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2, color: Ex.faint),
                  )
                : Text('ADD TO THE ROSTER',
                    style: Ex.dataStrong.copyWith(
                        color: const Color(0xFF3A2408), letterSpacing: 1.8)),
          ),
        ],
        ),
      ),
    );
  }

  Widget _photoWell() {
    return GestureDetector(
      onTap: _pickImage,
      child: Ex.disc(
        size: 172,
        glow: _photo == null ? Ex.mute : Ex.safelight,
        glowStrength: _photo == null ? 0.25 : 0.6,
        filled: _photo == null,
        child: _photo != null
            ? Image(
                image: (kIsWeb
                    ? NetworkImage(_photo!.path)
                    : FileImage(File(_photo!.path))) as ImageProvider,
                fit: BoxFit.cover,
                width: 172,
                height: 172,
              )
            : Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const Icon(Icons.add_a_photo_outlined, color: Ex.mute, size: 30),
                  const SizedBox(height: 10),
                  Text('CHOOSE A PHOTO',
                      style: Ex.data.copyWith(fontSize: 9.5, letterSpacing: 1.6)),
                ],
              ),
      ),
    );
  }
}
