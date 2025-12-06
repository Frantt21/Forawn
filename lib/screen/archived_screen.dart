import 'dart:io';
import 'package:flutter/material.dart';
import '../models/note.dart';
import '../db/notes_database.dart';

typedef TextGetter = String Function(String key, {String? fallback});

class ArchivedScreen extends StatefulWidget {
  final TextGetter getText;
  final String currentLang;
  const ArchivedScreen({
    super.key,
    required this.getText,
    required this.currentLang,
  });

  @override
  State<ArchivedScreen> createState() => _ArchivedScreenState();
}

class _ArchivedScreenState extends State<ArchivedScreen> {
  final _db = NotesDatabase.instance;
  late Future<List<Note>> _archivedFuture;

  @override
  void initState() {
    super.initState();
    _loadArchived();
  }

  void _loadArchived() {
    _archivedFuture = _db
        .readAllNotes(includeArchived: true, includeDeleted: true)
        .then((all) => all.where((n) => n.isArchived && !n.isDeleted).toList());
    setState(() {});
  }

  Future<void> _unarchive(Note note) async {
    await _db.unarchiveNote(note.id!);
    _loadArchived();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          widget.getText('archived', fallback: 'Nota desarchivada'),
        ),
        action: SnackBarAction(
          label: widget.getText('unpin', fallback: 'Deshacer'),
          onPressed: () async {
            await _db.archiveNote(note.id!);
            _loadArchived();
          },
        ),
      ),
    );
  }

  Future<void> _moveToTrash(Note note) async {
    await _db.moveToTrash(note.id!);
    _loadArchived();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          widget.getText(
            'moved_to_trash',
            fallback: 'Nota movida a la papelera',
          ),
        ),
      ),
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
              _unarchive(note);
            },
            child: Text(widget.getText('unarchive', fallback: 'Desarchivar')),
          ),
          ElevatedButton(
            onPressed: () {
              Navigator.pop(context);
              _moveToTrash(note);
            },
            child: Text(
              widget.getText('move_to_trash', fallback: 'Mover a papelera'),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildList(List<Note> notes) {
    if (notes.isEmpty) {
      return Center(
        child: Text(
          widget.getText('no_archived', fallback: 'No hay notas archivadas'),
        ),
      );
    }
    return ListView.separated(
      padding: const EdgeInsets.all(12),
      itemCount: notes.length,
      separatorBuilder: (_, __) => const SizedBox(height: 8),
      itemBuilder: (context, index) {
        final note = notes[index];
        return Dismissible(
          key: ValueKey(note.id),
          direction: DismissDirection.endToStart,
          background: Container(
            color: Colors.red,
            alignment: Alignment.centerRight,
            padding: const EdgeInsets.symmetric(horizontal: 20),
            child: const Icon(Icons.delete, color: Colors.white),
          ),
          onDismissed: (_) async {
            await _moveToTrash(note);
          },
          child: Card(
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
                  if (v == 'unarchive') _unarchive(note);
                  if (v == 'trash') _moveToTrash(note);
                },
                itemBuilder: (_) => [
                  PopupMenuItem(
                    value: 'unarchive',
                    child: Text(
                      widget.getText('unarchive', fallback: 'Desarchivar'),
                    ),
                  ),
                  PopupMenuItem(
                    value: 'trash',
                    child: Text(
                      widget.getText(
                        'move_to_trash',
                        fallback: 'Mover a papelera',
                      ),
                    ),
                  ),
                ],
              ),
              onTap: () => _showPreview(note),
            ),
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final scaffoldBg = const Color.fromARGB(255, 27, 27, 27);
    return FutureBuilder<List<Note>>(
      future: _archivedFuture,
      builder: (context, snapshot) {
        final notes = snapshot.data ?? [];
        return Scaffold(
          backgroundColor: scaffoldBg,
          body: RefreshIndicator(
            onRefresh: () async {
              _loadArchived();
              await _archivedFuture;
            },
            child: snapshot.connectionState == ConnectionState.waiting
                ? const Center(child: CircularProgressIndicator())
                : _buildList(notes),
          ),
        );
      },
    );
  }
}
