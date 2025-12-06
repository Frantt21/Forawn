import 'dart:async';
import 'dart:io';
import 'package:path/path.dart';
import 'package:sqflite/sqflite.dart';
import '../models/note.dart';

class NotesDatabase {
  NotesDatabase._init();
  static final NotesDatabase instance = NotesDatabase._init();
  static Database? _database;

  static const String dbName = 'notes.db';
  static const int dbVersion = 1;

  static const String tableNotes = 'notes';

  Future<Database> get database async {
    if (_database != null) return _database!;
    _database = await _initDB();
    return _database!;
  }

  Future<String> _computePath() async {
    try {
      final exec = Platform.resolvedExecutable;
      if (exec.isNotEmpty) {
        final dir = File(exec).parent.path;
        final candidate = join(dir, dbName);
        return candidate;
      }
    } catch (_) {}
    final dbPath = await getDatabasesPath();
    return join(dbPath, dbName);
  }

  Future<Database> _initDB() async {
    final path = await _computePath();
    return await openDatabase(
      path,
      version: dbVersion,
      onConfigure: _onConfigure,
      onCreate: _onCreate,
      onUpgrade: _onUpgrade,
    );
  }

  FutureOr<void> _onConfigure(Database db) async {
    await db.execute('PRAGMA foreign_keys = ON');
  }

  FutureOr<void> _onCreate(Database db, int version) async {
    await db.execute('''
      CREATE TABLE $tableNotes (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        title TEXT NOT NULL,
        description TEXT NOT NULL,
        content TEXT NOT NULL,
        imagePath TEXT,
        category TEXT,
        createdAt TEXT NOT NULL,
        updatedAt TEXT,
        isArchived INTEGER NOT NULL DEFAULT 0,
        isDeleted INTEGER NOT NULL DEFAULT 0,
        pinned INTEGER NOT NULL DEFAULT 0,
        backgroundColorValue INTEGER NOT NULL DEFAULT 0xFF121212
      )
    ''');
    await db.execute('CREATE INDEX idx_notes_deleted ON $tableNotes(isDeleted)');
    await db.execute('CREATE INDEX idx_notes_archived ON $tableNotes(isArchived)');
    await db.execute('CREATE INDEX idx_notes_createdAt ON $tableNotes(createdAt)');
  }

  FutureOr<void> _onUpgrade(Database db, int oldV, int newV) async {
    // migraciones futuras
  }

  // CRUD básicos
  Future<Note?> readNoteById(int id) async {
    final db = await database;
    final rows = await db.query(tableNotes, where: 'id = ?', whereArgs: [id], limit: 1);
    if (rows.isEmpty) return null;
    return Note.fromMap(rows.first);
  }

  Future<Note> createNote(Note note) async {
    final db = await database;
    final id = await db.insert(tableNotes, note.toMap());
    return note.copyWith(id: id);
  }

  Future<int> updateNote(Note note) async {
    final db = await database;
    final map = note.toMap()..remove('id');
    map['updatedAt'] = DateTime.now().toIso8601String();
    return db.update(tableNotes, map, where: 'id = ?', whereArgs: [note.id]);
  }

  Future<int> moveToTrash(int id) async {
    final db = await database;
    return db.update(tableNotes, {'isDeleted': 1, 'updatedAt': DateTime.now().toIso8601String()},
        where: 'id = ?', whereArgs: [id]);
  }

  Future<int> restoreFromTrash(int id) async {
    final db = await database;
    return db.update(tableNotes, {'isDeleted': 0, 'updatedAt': DateTime.now().toIso8601String()},
        where: 'id = ?', whereArgs: [id]);
  }

  Future<int> archiveNote(int id) async {
    final db = await database;
    return db.update(tableNotes, {'isArchived': 1, 'updatedAt': DateTime.now().toIso8601String()},
        where: 'id = ?', whereArgs: [id]);
  }

  Future<int> unarchiveNote(int id) async {
    final db = await database;
    return db.update(tableNotes, {'isArchived': 0, 'updatedAt': DateTime.now().toIso8601String()},
        where: 'id = ?', whereArgs: [id]);
  }

  Future<int> deleteNotePermanently(int id) async {
    final db = await database;
    return db.delete(tableNotes, where: 'id = ?', whereArgs: [id]);
  }

  Future<List<Note>> readAllNotes({bool includeArchived = false, bool includeDeleted = false}) async {
    final db = await database;
    final whereParts = <String>[];
    if (!includeDeleted) whereParts.add('isDeleted = 0');
    if (!includeArchived) whereParts.add('isArchived = 0');
    final where = whereParts.isEmpty ? null : whereParts.join(' AND ');
    final rows = await db.query(tableNotes, where: where, orderBy: 'pinned DESC, updatedAt DESC, createdAt DESC');
    return rows.map((r) => Note.fromMap(r)).toList();
  }

  Future<void> importNotes(List<Map<String, dynamic>> maps, {bool ignoreConflicts = true}) async {
    final db = await database;
    await db.transaction((txn) async {
      for (final m in maps) {
        final copy = Map<String, dynamic>.from(m);
        copy.remove('id');
        await txn.insert(tableNotes, copy);
      }
    });
  }

  Future<void> close() async {
    final db = _database;
    if (db != null) await db.close();
    _database = null;
  }

  // Métodos añadidos solicitados

  /// Exporta todas las filas como lista de mapas
  Future<List<Map<String, dynamic>>> exportAllNotes({bool includeDeleted = true}) async {
    final db = await database;
    final where = includeDeleted ? null : 'isDeleted = 0';
    final rows = await db.query(tableNotes, where: where);
    return rows;
  }

  /// Ejecuta una acción dentro de una transacción y retorna su resultado genérico
  Future<T> runInTransaction<T>(Future<T> Function(Transaction txn) action) async {
    final db = await database;
    return await db.transaction<T>((txn) async {
      return await action(txn);
    });
  }

  /// Elimina físicamente el archivo de la base de datos (cierra antes)
  Future<void> deleteDatabaseFile() async {
    final path = await _computePath();
    await close();
    try {
      await deleteDatabase(path);
    } catch (_) {
    }
  }
}
