import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../models/playlist_model.dart';
import '../services/playlist_service.dart';
import 'forawn_dialog.dart';

typedef DialogTextGetter = String Function(String key, {String? fallback});

/// Diálogo CREAR playlist — contenedor unificado [ForawnDialog] (mismo
/// estilo y tamaño que editar/agregar canciones).
class PlaylistCreateDialog extends StatefulWidget {
  final DialogTextGetter getText;
  final Color? accentColor;

  const PlaylistCreateDialog({
    super.key,
    required this.getText,
    this.accentColor,
  });

  @override
  State<PlaylistCreateDialog> createState() => _PlaylistCreateDialogState();
}

class _PlaylistCreateDialogState extends State<PlaylistCreateDialog> {
  final TextEditingController _nameController = TextEditingController();
  final TextEditingController _descController = TextEditingController();
  String? _selectedImagePath;

  @override
  void dispose() {
    _nameController.dispose();
    _descController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final accent = widget.accentColor ?? Colors.purpleAccent;
    return ForawnDialog(
      title: widget.getText('create_playlist', fallback: 'Create Playlist'),
      cancelLabel: widget.getText('cancel', fallback: 'Cancel'),
      confirmLabel: widget.getText('create', fallback: 'Create'),
      accentColor: accent,
      confirmEnabled: _nameController.text.trim().isNotEmpty,
      onConfirm: () {
        if (_nameController.text.trim().isEmpty) return;
        PlaylistService().createPlaylist(
          _nameController.text.trim(),
          description: _descController.text.trim(),
          imagePath: _selectedImagePath,
        );
        Navigator.pop(context);
      },
      children: [
        // Imagen opcional (radio 16, cuadrada, como mobile).
        Center(
          child: MouseRegion(
            cursor: SystemMouseCursors.click,
            child: GestureDetector(
              onTap: _pickImage,
              child: Container(
                width: 110,
                height: 110,
                decoration: BoxDecoration(
                  color: Colors.white.withOpacity(0.05),
                  borderRadius: BorderRadius.circular(16),
                  image: _selectedImagePath != null
                      ? DecorationImage(
                          image: FileImage(File(_selectedImagePath!)),
                          fit: BoxFit.cover,
                        )
                      : null,
                ),
                child: _selectedImagePath == null
                    ? Icon(
                        Icons.add_photo_alternate,
                        color: Colors.white.withOpacity(0.4),
                        size: 36,
                      )
                    : null,
              ),
            ),
          ),
        ),
        const SizedBox(height: 20),
        ForawnDialogInput(
          controller: _nameController,
          hint: widget.getText('name', fallback: 'Name'),
          prefixIcon: Icons.queue_music_rounded,
          accentColor: accent,
          onChanged: (_) => setState(() {}),
        ),
        const SizedBox(height: 16),
        ForawnDialogInput(
          controller: _descController,
          hint: widget.getText('description', fallback: 'Description'),
          maxLines: 3,
          accentColor: accent,
        ),
      ],
    );
  }

  Future<void> _pickImage() async {
    try {
      final result = await FilePicker.pickFiles(type: FileType.image);
      final path = result?.files.single.path;
      if (path != null && mounted) {
        setState(() => _selectedImagePath = path);
      }
    } catch (_) {}
  }
}

/// Diálogo EDITAR playlist — contenedor unificado [ForawnDialog].
class PlaylistEditDialog extends StatefulWidget {
  final Playlist playlist;
  final DialogTextGetter getText;
  final Color? accentColor;

  const PlaylistEditDialog({
    super.key,
    required this.playlist,
    required this.getText,
    this.accentColor,
  });

  @override
  State<PlaylistEditDialog> createState() => _PlaylistEditDialogState();
}

class _PlaylistEditDialogState extends State<PlaylistEditDialog> {
  late final TextEditingController _nameController;
  late final TextEditingController _descController;
  String? _selectedImagePath;

  @override
  void initState() {
    super.initState();
    _nameController = TextEditingController(text: widget.playlist.name);
    _descController = TextEditingController(text: widget.playlist.description);
    _selectedImagePath = widget.playlist.imagePath;
  }

  @override
  void dispose() {
    _nameController.dispose();
    _descController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final accent = widget.accentColor ?? Colors.purpleAccent;
    return ForawnDialog(
      title: widget.getText('edit_playlist', fallback: 'Edit Playlist'),
      cancelLabel: widget.getText('cancel', fallback: 'Cancel'),
      confirmLabel: widget.getText('save', fallback: 'Save'),
      accentColor: accent,
      confirmEnabled: _nameController.text.trim().isNotEmpty,
      onConfirm: () {
        if (_nameController.text.trim().isEmpty) return;
        PlaylistService().updatePlaylist(
          widget.playlist.id,
          name: _nameController.text.trim(),
          description: _descController.text.trim(),
          imagePath: _selectedImagePath,
        );
        Navigator.pop(context);
      },
      children: [
        Center(
          child: MouseRegion(
            cursor: SystemMouseCursors.click,
            child: GestureDetector(
              onTap: _pickImage,
              child: Container(
                width: 110,
                height: 110,
                decoration: BoxDecoration(
                  color: Colors.white.withOpacity(0.05),
                  borderRadius: BorderRadius.circular(16),
                  image: _selectedImagePath != null
                      ? DecorationImage(image: _imageProvider, fit: BoxFit.cover)
                      : null,
                ),
                child: _selectedImagePath == null
                    ? Icon(
                        Icons.add_a_photo,
                        color: Colors.white.withOpacity(0.4),
                        size: 36,
                      )
                    : null,
              ),
            ),
          ),
        ),
        const SizedBox(height: 20),
        ForawnDialogInput(
          controller: _nameController,
          hint: widget.getText('name', fallback: 'Name'),
          prefixIcon: Icons.queue_music_rounded,
          accentColor: accent,
          onChanged: (_) => setState(() {}),
        ),
        const SizedBox(height: 16),
        ForawnDialogInput(
          controller: _descController,
          hint: widget.getText('description', fallback: 'Description'),
          maxLines: 3,
          accentColor: accent,
        ),
      ],
    );
  }

  /// La imagen existente puede ser archivo local o URL (red).
  ImageProvider get _imageProvider {
    final path = _selectedImagePath!;
    if (path.startsWith('http')) return NetworkImage(path);
    final file = File(path);
    return file.existsSync()
        ? FileImage(file) as ImageProvider
        : NetworkImage(path) as ImageProvider;
  }

  Future<void> _pickImage() async {
    try {
      final result = await FilePicker.pickFiles(type: FileType.image);
      final path = result?.files.single.path;
      if (path != null && mounted) {
        setState(() => _selectedImagePath = path);
      }
    } catch (_) {}
  }
}
