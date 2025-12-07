import 'dart:io';
import 'package:flutter/material.dart';
import '../models/note.dart';
import '../db/notes_database.dart';
import '../widgets/elegant_notification.dart';

typedef TextGetter = String Function(String key, {String? fallback});

class TrashScreen extends StatefulWidget {
  final TextGetter getText;
  final String currentLang;
  const TrashScreen({
    super.key,
    required this.getText,
    required this.currentLang,
  });

  @override
  State<TrashScreen> createState() => _TrashScreenState();
}

class _TrashScreenState extends State<TrashScreen> {
  final _db = NotesDatabase.instance;
  late Future<List<Note>> _trashFuture;

  @override
  void initState() {
    super.initState();
    _loadTrash();
  }

  void _loadTrash() {
    _trashFuture = _db
        .readAllNotes(includeArchived: true, includeDeleted: true)
        .then((all) => all.where((n) => n.isDeleted).toList());
    setState(() {});
  }

  Future<void> _restore(Note note) async {
    await _db.restoreFromTrash(note.id!);
    _loadTrash();
    showElegantNotification(
      context,
      widget.getText('moved_to_trash', fallback: 'Nota restaurada'),
      backgroundColor: const Color(0xFF2C2C2C),
      textColor: Colors.white,
      icon: Icons.restore,
      iconColor: Colors.blue,
    );
  }

  Future<void> _deletePermanently(Note note) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: Text(widget.getText('delete', fallback: 'Eliminar')),
        content: Text(
          widget.getText(
            'delete_permanent_confirm',
            fallback:
                '¿Eliminar esta nota de forma permanente? Esta acción no se puede deshacer.',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(widget.getText('cancel', fallback: 'Cancelar')),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(widget.getText('delete', fallback: 'Eliminar')),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    await _db.deleteNotePermanently(note.id!);
    _loadTrash();

    showElegantNotification(
      context,
      widget.getText('delete', fallback: 'Nota eliminada permanentemente'),
      backgroundColor: const Color(0xFFE53935),
      textColor: Colors.white,
      icon: Icons.delete_outline,
      iconColor: Colors.white,
    );
  }

  Future<void> _emptyTrash() async {
    final notes = await _trashFuture;
    if (notes.isEmpty) {
      showElegantNotification(
        context,
        widget.getText('no_notes', fallback: 'La papelera ya está vacía'),
        backgroundColor: const Color(0xFF2C2C2C),
        textColor: Colors.white,
        icon: Icons.info_outline,
        iconColor: Colors.white70,
      );
      return;
    }

    final confirm = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: Text(widget.getText('empty_trash', fallback: 'Vaciar papelera')),
        content: Text(
          (widget.getText(
            'empty_trash_confirm',
            fallback:
                '¿Vaciar la papelera? Esta acción eliminará todas las notas de forma permanente.',
          )),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancelar'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Vaciar'),
          ),
        ],
      ),
    );
    if (confirm != true) return;

    for (final n in notes) {
      await _db.deleteNotePermanently(n.id!);
    }
    _loadTrash();

    showElegantNotification(
      context,
      '${widget.getText('empty_trash', fallback: 'Papelera vaciada')} (${notes.length})',
      backgroundColor: const Color(0xFF2C2C2C),
      textColor: Colors.white,
      icon: Icons.delete_sweep,
      iconColor: Colors.orange,
    );
  }

  void _showPreview(Note note) {
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        title: Text(note.title),
        content: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (note.imagePath != null && File(note.imagePath!).existsSync())
                Image.file(File(note.imagePath!)),
              const SizedBox(height: 8),
              Text(note.description),
              const SizedBox(height: 8),
              Text(note.content),
              const SizedBox(height: 8),
              if (note.category != null) Chip(label: Text(note.category!)),
              const SizedBox(height: 8),
              Text(
                '${widget.getText('created_at', fallback: 'Creada')}: ${note.createdAt.toLocal().toString().split('.').first}',
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(widget.getText('close', fallback: 'Cerrar')),
          ),
          TextButton(
            onPressed: () {
              Navigator.pop(context);
              _restore(note);
            },
            child: Text(widget.getText('restore', fallback: 'Restaurar')),
          ),
          ElevatedButton(
            onPressed: () {
              Navigator.pop(context);
              _deletePermanently(note);
            },
            child: Text(widget.getText('delete', fallback: 'Eliminar')),
          ),
        ],
      ),
    );
  }

  Widget _buildList(List<Note> notes) {
    if (notes.isEmpty) {
      return Center(
        child: Text(
          widget.getText('no_notes', fallback: 'La papelera está vacía'),
        ),
      );
    }
    return ListView.separated(
      padding: const EdgeInsets.all(12),
      itemCount: notes.length,
      separatorBuilder: (_, __) => const SizedBox(height: 8),
      itemBuilder: (context, index) {
        final note = notes[index];
        return Card(
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(10),
          ),
          child: ListTile(
            leading:
                note.imagePath != null && File(note.imagePath!).existsSync()
                ? Image.file(
                    File(note.imagePath!),
                    width: 56,
                    height: 56,
                    fit: BoxFit.cover,
                  )
                : null,
            title: Text(note.title),
            subtitle: Text(
              note.description,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
            trailing: PopupMenuButton<String>(
              onSelected: (v) {
                if (v == 'restore') _restore(note);
                if (v == 'delete') _deletePermanently(note);
              },
              itemBuilder: (_) => [
                PopupMenuItem(
                  value: 'restore',
                  child: Text(widget.getText('restore', fallback: 'Restaurar')),
                ),
                PopupMenuItem(
                  value: 'delete',
                  child: Text(
                    widget.getText(
                      'delete',
                      fallback: 'Eliminar permanentemente',
                    ),
                  ),
                ),
              ],
            ),
            onTap: () => _showPreview(note),
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final scaffoldBg = const Color.fromARGB(255, 27, 27, 27);
    return FutureBuilder<List<Note>>(
      future: _trashFuture,
      builder: (context, snapshot) {
        final notes = snapshot.data ?? [];
        final count = notes.length;
        return Scaffold(
          backgroundColor: scaffoldBg,
          body: RefreshIndicator(
            onRefresh: () async {
              _loadTrash();
              await _trashFuture;
            },
            child: snapshot.connectionState == ConnectionState.waiting
                ? const Center(child: CircularProgressIndicator())
                : _buildList(notes),
          ),
          floatingActionButton: count > 0
              ? FloatingActionButton.extended(
                  onPressed: _emptyTrash,
                  icon: const Icon(Icons.delete_forever),
                  label: Text(
                    widget.getText('empty_trash', fallback: 'Vaciar papelera'),
                  ),
                  backgroundColor: Colors.red,
                )
              : null,
        );
      },
    );
  }
}
