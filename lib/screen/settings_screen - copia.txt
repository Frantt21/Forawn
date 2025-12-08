import 'dart:convert';
import 'package:flutter/material.dart';
import '../db/notes_database.dart';
import '../widgets/elegant_notification.dart';

typedef TextGetter = String Function(String key, {String? fallback});

class SettingsScreen2 extends StatefulWidget {
  final TextGetter getText;
  final String currentLang;
  const SettingsScreen2({super.key, required this.getText, required this.currentLang});

  @override
  State<SettingsScreen2> createState() => _SettingsScreen2State();
}

class _SettingsScreen2State extends State<SettingsScreen2> {
  final _db = NotesDatabase.instance;
  // bool _compactMode = false;

  Future<void> _exportJson() async {
    final rows = await _db.exportAllNotes(includeDeleted: true);
    final jsonText = const JsonEncoder.withIndent('  ').convert(rows);
    await showDialog(
      context: context,
      builder: (_) => AlertDialog(
        title: Text(widget.getText('export_json', fallback: 'Exportar JSON')),
        content: SingleChildScrollView(child: SelectableText(jsonText)),
        actions: [TextButton(onPressed: () => Navigator.pop(context), child: Text(widget.getText('close', fallback: 'Cerrar')))],
      ),
    );
  }

  Future<void> _importJson() async {
    final controller = TextEditingController();
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: Text(widget.getText('import_json', fallback: 'Importar JSON')),
        content: TextField(controller: controller, decoration: InputDecoration(hintText: widget.getText('paste_json_here', fallback: 'Pega JSON aquí')), maxLines: 8),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: Text(widget.getText('cancel', fallback: 'Cancelar'))),
          ElevatedButton(onPressed: () => Navigator.pop(context, true), child: Text(widget.getText('import', fallback: 'Importar'))),
        ],
      ),
    );
    if (confirmed != true) return;
    try {
      final list = json.decode(controller.text) as List<dynamic>;
      final maps = list.cast<Map<String, dynamic>>();
      await _db.importNotes(maps, ignoreConflicts: true);
      showElegantNotification(
        context,
        widget.getText('import_done', fallback: 'Importación completada'),
        backgroundColor: const Color(0xFF2C2C2C),
        textColor: Colors.white,
        icon: Icons.check_circle_outline,
        iconColor: Colors.green,
      );
    } catch (e) {
      showElegantNotification(
        context,
        widget.getText('invalid_json', fallback: 'JSON inválido'),
        backgroundColor: const Color(0xFFE53935),
        textColor: Colors.white,
        icon: Icons.error_outline,
        iconColor: Colors.white,
      );
    }
  }

  Future<void> _clearTrash() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Vaciar papelera'),
        content: const Text('¿Eliminar todas las notas en la papelera permanentemente?'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancelar')),
          ElevatedButton(onPressed: () => Navigator.pop(context, true), child: const Text('Vaciar')),
        ],
      ),
    );
    if (confirmed != true) return;

    final notes = await _db.readAllNotes(includeArchived: true, includeDeleted: true).then((all) => all.where((n) => n.isDeleted).toList());
    await _db.runInTransaction((txn) async {
      for (final n in notes) {
        await txn.delete(NotesDatabase.tableNotes, where: 'id = ?', whereArgs: [n.id]);
      }
      return Future.value(true);
    });

    showElegantNotification(
      context,
      'Papelera vaciada',
      backgroundColor: const Color(0xFF2C2C2C),
      textColor: Colors.white,
      icon: Icons.delete_sweep,
      iconColor: Colors.orange,
    );
  }

  Future<void> _deleteDatabase() async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: Text(widget.getText('delete_database', fallback: 'Eliminar base de datos')),
        content: Text(widget.getText('delete_database_confirm', fallback: 'Eliminar notes.db permanentemente? Esta acción borra todas las notas.')),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: Text(widget.getText('cancel', fallback: 'Cancelar'))),
          ElevatedButton(onPressed: () => Navigator.pop(context, true), child: Text(widget.getText('delete', fallback: 'Eliminar'))),
        ],
      ),
    );
    if (confirm != true) return;
    await _db.deleteDatabaseFile();
    showElegantNotification(
      context,
      widget.getText('database_deleted', fallback: 'Base de datos eliminada'),
      backgroundColor: const Color(0xFF2C2C2C),
      textColor: Colors.white,
      icon: Icons.delete_outline,
      iconColor: Colors.red,
    );
  }

  @override
  Widget build(BuildContext context) {
    final scaffoldBg = const Color.fromARGB(255, 27, 27, 27);
    final t = widget.getText;
    return Scaffold(
      backgroundColor: scaffoldBg,
      appBar: AppBar(title: Text(t('settings', fallback: 'Ajustes'))),
      body: ListView(
        children: [
          // SwitchListTile(
          //   title: Text(t('compact_mode', fallback: 'Modo compacto')),
          //   subtitle: Text(t('compact_mode_sub', fallback: 'Reducir espaciado en tarjetas y listas')),
          //   value: _compactMode,
          //   onChanged: (v) => setState(() => _compactMode = v),
          // ),
          ListTile(
            leading: const Icon(Icons.upload_file),
            title: Text(t('export_json', fallback: 'Exportar notas (JSON)')),
            onTap: _exportJson,
          ),
          ListTile(
            leading: const Icon(Icons.download),
            title: Text(t('import_json', fallback: 'Importar notas (JSON)')),
            onTap: _importJson,
          ),
          ListTile(
            leading: const Icon(Icons.delete_forever),
            title: Text(t('empty_trash', fallback: 'Vaciar papelera')),
            onTap: _clearTrash,
          ),
          ListTile(
            leading: const Icon(Icons.delete),
            title: Text(t('delete_database', fallback: 'Eliminar base de datos (solo para pruebas)')),
            onTap: _deleteDatabase,
          ),
        ],
      ),
    );
  }
}
