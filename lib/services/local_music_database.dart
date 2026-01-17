import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:sqflite/sqflite.dart';
import 'package:path/path.dart' as p;
import 'package:audio_metadata_reader/audio_metadata_reader.dart';
import 'package:palette_generator/palette_generator.dart';
import 'dart:ui';

class LocalMusicDatabase extends ChangeNotifier {
  static final LocalMusicDatabase _instance = LocalMusicDatabase._internal();
  factory LocalMusicDatabase() => _instance;
  LocalMusicDatabase._internal();

  Database? _database;

  // Caché en memoria para acceso ultra-rápido
  final Map<String, SongMetadata> _metadataCache = {};
  final Map<String, Color> _colorCache = {};

  bool _isInitialized = false;

  /// Inicializar la base de datos
  Future<void> initialize() async {
    if (_isInitialized) return;

    try {
      final dbPath = await getDatabasesPath();
      final path = p.join(dbPath, 'local_music.db');

      _database = await openDatabase(
        path,
        version: 2,
        onCreate: (db, version) async {
          // Tabla de metadatos
          await db.execute('''
            CREATE TABLE metadata (
              file_path TEXT PRIMARY KEY,
              title TEXT NOT NULL,
              artist TEXT NOT NULL,
              album TEXT,
              duration_ms INTEGER,
              artwork_hash TEXT,
              created_at INTEGER NOT NULL,
              updated_at INTEGER NOT NULL
            )
          ''');

          // Tabla de colores dominantes
          await db.execute('''
            CREATE TABLE colors (
              file_path TEXT PRIMARY KEY,
              dominant_color INTEGER NOT NULL,
              vibrant_color INTEGER,
              created_at INTEGER NOT NULL,
              FOREIGN KEY (file_path) REFERENCES metadata (file_path) ON DELETE CASCADE
            )
          ''');

          // Tabla de artworks (almacenados como archivos en disco)
          await db.execute('''
            CREATE TABLE artworks (
              artwork_hash TEXT PRIMARY KEY,
              file_path TEXT NOT NULL,
              width INTEGER,
              height INTEGER,
              created_at INTEGER NOT NULL
            )
          ''');

          // Tabla de historial de reproducción
          await db.execute('''
            CREATE TABLE play_history (
              id INTEGER PRIMARY KEY AUTOINCREMENT,
              file_path TEXT NOT NULL,
              played_at INTEGER NOT NULL
            )
          ''');

          // Índices para búsquedas rápidas
          await db.execute('CREATE INDEX idx_title ON metadata(title)');
          await db.execute('CREATE INDEX idx_artist ON metadata(artist)');
          await db.execute('CREATE INDEX idx_album ON metadata(album)');
          await db.execute(
            'CREATE INDEX idx_history_time ON play_history(played_at DESC)',
          );
        },
        onUpgrade: (db, oldVersion, newVersion) async {
          if (oldVersion < 2) {
            // Migración a v2: Crear tabla de historial
            await db.execute('''
              CREATE TABLE play_history (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                file_path TEXT NOT NULL,
                played_at INTEGER NOT NULL
              )
            ''');
            await db.execute(
              'CREATE INDEX idx_history_time ON play_history(played_at DESC)',
            );
          }
        },
      );

      _isInitialized = true;
      debugPrint('[LocalMusicDB] Database initialized successfully');
    } catch (e) {
      debugPrint('[LocalMusicDB] Error initializing database: $e');
      rethrow;
    }
  }

  /// Obtener metadatos de una canción
  /// Si no existe en la DB, los carga del archivo automáticamente
  Future<SongMetadata?> getMetadata(String filePath) async {
    if (!_isInitialized) await initialize();

    // 1. Verificar caché en memoria
    if (_metadataCache.containsKey(filePath)) {
      return _metadataCache[filePath];
    }

    // 2. Verificar base de datos
    try {
      final result = await _database!.query(
        'metadata',
        where: 'file_path = ?',
        whereArgs: [filePath],
        limit: 1,
      );

      if (result.isNotEmpty) {
        final metadata = SongMetadata.fromMap(result.first);

        // Cargar artwork si existe
        if (metadata.artworkHash != null) {
          metadata.artwork = await _loadArtwork(metadata.artworkHash!);
        }

        _metadataCache[filePath] = metadata;
        return metadata;
      }
    } catch (e) {
      debugPrint('[LocalMusicDB] Error reading from database: $e');
    }

    // 3. Cargar desde archivo (primera vez)
    return await _loadAndCacheMetadata(filePath);
  }

  /// Obtener color dominante de una canción
  /// Si no existe, lo extrae del artwork automáticamente
  Future<Color?> getDominantColor(String filePath) async {
    if (!_isInitialized) await initialize();

    // 1. Verificar caché en memoria
    if (_colorCache.containsKey(filePath)) {
      return _colorCache[filePath];
    }

    // 2. Verificar base de datos
    try {
      final result = await _database!.query(
        'colors',
        where: 'file_path = ?',
        whereArgs: [filePath],
        limit: 1,
      );

      if (result.isNotEmpty) {
        final colorValue = result.first['dominant_color'] as int;
        final color = Color(colorValue);
        _colorCache[filePath] = color;
        return color;
      }
    } catch (e) {
      debugPrint('[LocalMusicDB] Error reading color from database: $e');
    }

    // 3. Extraer del artwork (primera vez)
    final metadata = await getMetadata(filePath);
    if (metadata?.artwork != null) {
      return await _extractAndCacheColor(filePath, metadata!.artwork!);
    }

    return null;
  }

  /// Cargar metadatos desde el archivo y guardarlos en la DB
  Future<SongMetadata?> _loadAndCacheMetadata(String filePath) async {
    try {
      final file = File(filePath);
      if (!await file.exists()) {
        debugPrint('[LocalMusicDB] File not found: $filePath');
        return null;
      }

      debugPrint(
        '[LocalMusicDB] Loading metadata from file: ${p.basename(filePath)}',
      );

      // Leer metadatos del archivo
      final meta = await compute(_readMetadataIsolate, filePath);

      final title =
          meta['title'] as String? ?? p.basenameWithoutExtension(filePath);
      final artist = meta['artist'] as String? ?? 'Unknown Artist';
      final album = meta['album'] as String?;
      final durationMs = meta['durationMs'] as int?;
      final artwork = meta['artwork'] as Uint8List?;

      // Guardar artwork en disco si existe
      String? artworkHash;
      if (artwork != null) {
        artworkHash = await _saveArtwork(artwork);
      }

      // Crear objeto de metadatos
      final metadata = SongMetadata(
        filePath: filePath,
        title: title,
        artist: artist,
        album: album,
        durationMs: durationMs,
        artwork: artwork,
        artworkHash: artworkHash,
      );

      // Guardar en base de datos
      await _database!.insert('metadata', {
        'file_path': filePath,
        'title': title,
        'artist': artist,
        'album': album,
        'duration_ms': durationMs,
        'artwork_hash': artworkHash,
        'created_at': DateTime.now().millisecondsSinceEpoch,
        'updated_at': DateTime.now().millisecondsSinceEpoch,
      }, conflictAlgorithm: ConflictAlgorithm.replace);

      // Guardar en caché
      _metadataCache[filePath] = metadata;

      // Notificar cambios
      notifyListeners();

      debugPrint('[LocalMusicDB] Metadata cached: $title - $artist');
      return metadata;
    } catch (e) {
      debugPrint('[LocalMusicDB] Error loading metadata: $e');
      return null;
    }
  }

  /// Extraer color dominante del artwork y guardarlo
  Future<Color?> _extractAndCacheColor(
    String filePath,
    Uint8List artwork,
  ) async {
    try {
      debugPrint(
        '[LocalMusicDB] Extracting color for: ${p.basename(filePath)}',
      );

      final paletteGenerator = await PaletteGenerator.fromImageProvider(
        MemoryImage(artwork),
        size: const Size(50, 50),
      );

      final dominantColor = paletteGenerator.dominantColor?.color;
      final vibrantColor = paletteGenerator.vibrantColor?.color;

      if (dominantColor != null) {
        // Guardar en base de datos
        await _database!.insert('colors', {
          'file_path': filePath,
          'dominant_color': dominantColor.value,
          'vibrant_color': vibrantColor?.value,
          'created_at': DateTime.now().millisecondsSinceEpoch,
        }, conflictAlgorithm: ConflictAlgorithm.replace);

        // Guardar en caché
        _colorCache[filePath] = dominantColor;

        // Notificar cambios
        notifyListeners();

        debugPrint('[LocalMusicDB] Color cached: ${dominantColor.value}');
        return dominantColor;
      }
    } catch (e) {
      debugPrint('[LocalMusicDB] Error extracting color: $e');
    }

    return null;
  }

  /// Guardar artwork en disco y retornar hash
  Future<String?> _saveArtwork(Uint8List artwork) async {
    try {
      final hash = artwork.hashCode.toString();
      final artworksDir = await _getArtworksDirectory();
      final file = File(p.join(artworksDir.path, '$hash.jpg'));

      if (!await file.exists()) {
        await file.writeAsBytes(artwork);

        // Guardar referencia en DB
        await _database!.insert('artworks', {
          'artwork_hash': hash,
          'file_path': file.path,
          'created_at': DateTime.now().millisecondsSinceEpoch,
        }, conflictAlgorithm: ConflictAlgorithm.ignore);
      }

      return hash;
    } catch (e) {
      debugPrint('[LocalMusicDB] Error saving artwork: $e');
      return null;
    }
  }

  /// Cargar artwork desde disco
  Future<Uint8List?> _loadArtwork(String hash) async {
    try {
      final result = await _database!.query(
        'artworks',
        where: 'artwork_hash = ?',
        whereArgs: [hash],
        limit: 1,
      );

      if (result.isNotEmpty) {
        final filePath = result.first['file_path'] as String;
        final file = File(filePath);

        if (await file.exists()) {
          return await file.readAsBytes();
        }
      }
    } catch (e) {
      debugPrint('[LocalMusicDB] Error loading artwork: $e');
    }

    return null;
  }

  /// Obtener directorio de artworks
  Future<Directory> _getArtworksDirectory() async {
    final dbPath = await getDatabasesPath();
    final artworksDir = Directory(p.join(dbPath, 'artworks'));

    if (!await artworksDir.exists()) {
      await artworksDir.create(recursive: true);
    }

    return artworksDir;
  }

  /// Precargar metadatos de múltiples archivos en batch
  Future<void> preloadBatch(
    List<String> filePaths, {
    void Function(int current, int total)? onProgress,
  }) async {
    if (!_isInitialized) await initialize();

    debugPrint('[LocalMusicDB] Preloading ${filePaths.length} files...');

    for (int i = 0; i < filePaths.length; i++) {
      await getMetadata(filePaths[i]);
      onProgress?.call(i + 1, filePaths.length);
    }

    debugPrint('[LocalMusicDB] Preload complete');
  }

  /// Limpiar caché en memoria (mantiene DB intacta)
  void clearMemoryCache() {
    _metadataCache.clear();
    _colorCache.clear();
    debugPrint('[LocalMusicDB] Memory cache cleared');
  }

  /// Limpiar toda la base de datos
  Future<void> clearDatabase() async {
    if (!_isInitialized) await initialize();

    try {
      await _database!.delete('colors');
      await _database!.delete('metadata');
      await _database!.delete('artworks');

      // Limpiar archivos de artwork
      final artworksDir = await _getArtworksDirectory();
      if (await artworksDir.exists()) {
        await artworksDir.delete(recursive: true);
      }

      clearMemoryCache();
      notifyListeners();

      debugPrint('[LocalMusicDB] Database cleared');
    } catch (e) {
      debugPrint('[LocalMusicDB] Error clearing database: $e');
    }
  }

  /// Obtener estadísticas de la base de datos
  Future<Map<String, int>> getStats() async {
    if (!_isInitialized) await initialize();

    try {
      final metadataCount =
          Sqflite.firstIntValue(
            await _database!.rawQuery('SELECT COUNT(*) FROM metadata'),
          ) ??
          0;

      final colorsCount =
          Sqflite.firstIntValue(
            await _database!.rawQuery('SELECT COUNT(*) FROM colors'),
          ) ??
          0;

      final artworksCount =
          Sqflite.firstIntValue(
            await _database!.rawQuery('SELECT COUNT(*) FROM artworks'),
          ) ??
          0;

      return {
        'metadata': metadataCount,
        'colors': colorsCount,
        'artworks': artworksCount,
        'memory_cache': _metadataCache.length,
      };
    } catch (e) {
      debugPrint('[LocalMusicDB] Error getting stats: $e');
      return {};
    }
  }

  /// --- HISTORY MANAGEMENT ---

  /// Agregar canción al historial
  Future<void> addToHistory(String filePath) async {
    if (!_isInitialized) await initialize();
    try {
      // Eliminar si ya existe recientemente (para evitar duplicados inmediatos)
      // Opcional: Podríamos dejar duplicados si queremos historial exacto
      // Vamos a eliminar duplicados de la misma canción para no saturar
      /*
      await _database!.delete(
        'play_history',
        where: 'file_path = ?',
        whereArgs: [filePath],
      );
      */

      await _database!.insert('play_history', {
        'file_path': filePath,
        'played_at': DateTime.now().millisecondsSinceEpoch,
      });

      // Limpieza automática: Mantener solo últimos 1000
      // Se puede ejecutar periódicamente o aquí
      // _trimHistory();
    } catch (e) {
      debugPrint('[LocalMusicDB] Error adding to history: $e');
    }
  }

  /// Obtener historial completo (o paginado)
  Future<List<String>> getHistory({int limit = 50}) async {
    if (!_isInitialized) await initialize();
    try {
      final results = await _database!.query(
        'play_history',
        orderBy: 'played_at DESC',
        limit: limit,
      );

      return results.map((e) => e['file_path'] as String).toList();
    } catch (e) {
      debugPrint('[LocalMusicDB] Error getting history: $e');
      return [];
    }
  }

  /// Borrar canción específica del historial (usado al retroceder)
  Future<void> removeFromHistory(String filePath) async {
    if (!_isInitialized) await initialize();
    try {
      // Borrar la entrada más reciente de esa canción
      // Esto es un poco complejo en SQL puro sin ID, pero podemos usar subquery
      // DELETE FROM play_history WHERE id = (SELECT id FROM play_history WHERE file_path = ? ORDER BY played_at DESC LIMIT 1)

      await _database!.rawDelete(
        '''
        DELETE FROM play_history 
        WHERE id = (
          SELECT id FROM play_history 
          WHERE file_path = ? 
          ORDER BY played_at DESC 
          LIMIT 1
        )
      ''',
        [filePath],
      );
    } catch (e) {
      debugPrint('[LocalMusicDB] Error removing from history: $e');
    }
  }

  /// Limpiar historial
  Future<void> clearHistoryOnly() async {
    if (!_isInitialized) await initialize();
    try {
      await _database!.delete('play_history');
    } catch (e) {
      debugPrint('[LocalMusicDB] Error clearing history: $e');
    }
  }

  /// Buscar canciones por título, artista o álbum
  Future<List<SongMetadata>> search(String query) async {
    if (!_isInitialized) await initialize();

    try {
      final results = await _database!.query(
        'metadata',
        where: 'title LIKE ? OR artist LIKE ? OR album LIKE ?',
        whereArgs: ['%$query%', '%$query%', '%$query%'],
        limit: 50,
      );

      return results.map((map) => SongMetadata.fromMap(map)).toList();
    } catch (e) {
      debugPrint('[LocalMusicDB] Error searching: $e');
      return [];
    }
  }

  @override
  void dispose() {
    _database?.close();
    super.dispose();
  }
}

/// Función para leer metadatos en un isolate (evita bloquear UI)
Map<String, dynamic> _readMetadataIsolate(String filePath) {
  try {
    final file = File(filePath);
    final meta = readMetadata(file, getImage: true);

    return {
      'title': meta.title,
      'artist': meta.artist,
      'album': meta.album,
      'durationMs': meta.duration?.inMilliseconds,
      'artwork': meta.pictures.isNotEmpty ? meta.pictures.first.bytes : null,
    };
  } catch (e) {
    return {};
  }
}

/// Modelo de metadatos de canción
class SongMetadata {
  final String filePath;
  final String title;
  final String artist;
  final String? album;
  final int? durationMs;
  final String? artworkHash;
  Uint8List? artwork;

  SongMetadata({
    required this.filePath,
    required this.title,
    required this.artist,
    this.album,
    this.durationMs,
    this.artworkHash,
    this.artwork,
  });

  factory SongMetadata.fromMap(Map<String, dynamic> map) {
    return SongMetadata(
      filePath: map['file_path'] as String,
      title: map['title'] as String,
      artist: map['artist'] as String,
      album: map['album'] as String?,
      durationMs: map['duration_ms'] as int?,
      artworkHash: map['artwork_hash'] as String?,
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'file_path': filePath,
      'title': title,
      'artist': artist,
      'album': album,
      'duration_ms': durationMs,
      'artwork_hash': artworkHash,
    };
  }
}
